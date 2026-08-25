{ config, pkgs, ... }:

let
  # The Artifact Registry Docker host the cluster pulls private images from.
  registryHost = config.nagare.host.registryHost;
  appNamespaces = [ "personal" ];

  # Refresh script: mint a fresh OAuth access token for the node service account
  # from the GCE metadata server and write k3s's per-registry credential file.
  # No secret is configured anywhere — the VM's attached service account
  # (nagare-node@<project>, cloud-platform scope) authorizes the mint. Artifact
  # Registry accepts such a token as username "oauth2accesstoken" / password=token.
  refreshScript = pkgs.writeShellScript "nagare-registries-refresh" ''
    set -euo pipefail
    TOKEN="$(${pkgs.curl}/bin/curl -sf -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
      | ${pkgs.jq}/bin/jq -r .access_token)"
    if [ -z "''${TOKEN}" ] || [ "''${TOKEN}" = "null" ]; then
      echo "nagare-registries-refresh: failed to mint a metadata access token" >&2
      exit 1
    fi
    install -d -m 0700 /etc/rancher/k3s
    umask 077
    cat > /etc/rancher/k3s/registries.yaml <<EOF
    configs:
      "${registryHost}":
        auth:
          username: oauth2accesstoken
          password: "''${TOKEN}"
    EOF
    chmod 0600 /etc/rancher/k3s/registries.yaml
    # k3s reads registries.yaml only at start. This file is therefore the bootstrap
    # credential for early pulls; steady-state pulls use the Kubernetes pull Secret
    # refreshed below, without restarting k3s.
  '';

  pullSecretScript = pkgs.writeShellScript "nagare-registry-pull-secret" ''
    set -euo pipefail

    TOKEN="$(${pkgs.curl}/bin/curl -sf -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
      | ${pkgs.jq}/bin/jq -r .access_token)"
    if [ -z "''${TOKEN}" ] || [ "''${TOKEN}" = "null" ]; then
      echo "nagare-registry-pull-secret: failed to mint a metadata access token" >&2
      exit 1
    fi

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    kubectl() {
      ${config.services.k3s.package}/bin/k3s kubectl "$@"
    }
    cluster_ready() {
      kubectl get --raw=/readyz --request-timeout=10s >/dev/null 2>&1
    }
    fail_or_retry() {
      message="$1"
      if ! cluster_ready; then
        echo "nagare-registry-pull-secret: cluster API is unavailable; timer will retry" >&2
        exit 0
      fi
      echo "nagare-registry-pull-secret: $message" >&2
      exit 1
    }

    if ! cluster_ready; then
      echo "nagare-registry-pull-secret: cluster API is unavailable; timer will retry" >&2
      exit 0
    fi

    for ns in ${builtins.concatStringsSep " " appNamespaces}; do
      if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "nagare-registry-pull-secret: namespace $ns does not exist; skipping" >&2
        continue
      fi

      if ! kubectl -n "$ns" create secret docker-registry nagare-registry-pull \
        --docker-server="${registryHost}" \
        --docker-username=oauth2accesstoken \
        --docker-password="$TOKEN" \
        --dry-run=client -o yaml \
        | kubectl -n "$ns" apply -f -; then
        fail_or_retry "failed to apply pull Secret in $ns"
      fi

      if ! kubectl -n "$ns" patch serviceaccount default \
        -p '{"imagePullSecrets":[{"name":"nagare-registry-pull"}]}'; then
        fail_or_retry "failed to patch the default ServiceAccount in $ns"
      fi
    done
  '';
in
{
  # EP-2 (MasterPlan 13): make private-image pull DURABLE and DECLARATIVE.
  #
  # The cluster pulls application images from the project's private Artifact
  # Registry. containerd reads per-registry credentials from
  # /etc/rancher/k3s/registries.yaml; without it the pull is anonymous and AR
  # returns 403/DENIED. Rather than a hand-written token that expires in ~1 hour
  # (the non-durable fix the 2026-06-10 audit applied), a metadata-minted token is
  # written on boot (before k3s). A Kubernetes pull Secret refreshed below is the
  # steady-state credential and reaches kubelet without restarting the control
  # plane.
  #
  # The boot unit remains useful during initial cluster startup. Once the API is
  # ready, nagare-registry-pull-secret refreshes per-pod credentials every 30
  # minutes and wires them into each app namespace's default ServiceAccount.
  systemd.services.nagare-registries-refresh = {
    description = "Refresh k3s Artifact Registry pull credentials from the metadata server";
    # The metadata server is link-local and available early, but require the
    # network stack so a cold boot does not race it.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Write a fresh token before k3s starts so the first pull is authenticated.
    # wantedBy (not requiredBy) means a
    # transient metadata blip never wedges k3s.
    before = [ "k3s.service" ];
    wantedBy = [ "k3s.service" "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = refreshScript;
    };
  };

  systemd.services.nagare-registry-pull-secret = {
    description = "Refresh Kubernetes Artifact Registry pull credentials";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils config.services.k3s.package ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pullSecretScript;
    };
  };

  systemd.timers.nagare-registry-pull-secret = {
    description = "Periodically refresh Kubernetes Artifact Registry pull credentials";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "30min";
      Persistent = true;
    };
  };
}
