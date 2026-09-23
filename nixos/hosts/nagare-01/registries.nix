{ config, pkgs, ... }:

let
  # The Artifact Registry Docker host the cluster pulls private images from.
  registryHost = config.nagare.host.registryHost;
  # Private platform images (such as the in-cluster Attic cache) run in
  # nagare-system, while user workloads run in personal.  Keep both default
  # ServiceAccounts wired to the short-lived Artifact Registry pull Secret.
  imagePullNamespaces = [ "personal" "nagare-system" ];
  registrySourceVersion = builtins.hashFile "sha256" ./registries.nix;

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
    # Preserve wheel traversal to the root:wheel 0640 kubeconfig. The registry
    # credential itself remains root-only below.
    install -d -m 0750 -o root -g wheel /etc/rancher/k3s
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

    METADATA="$(${pkgs.curl}/bin/curl -sf -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'
    )"
    if ! TOKEN="$(printf '%s' "$METADATA" | ${pkgs.jq}/bin/jq -er \
      '.access_token | select(type == "string" and length > 0)')" \
      || ! LIFETIME="$(printf '%s' "$METADATA" | ${pkgs.jq}/bin/jq -er \
        '.expires_in | select(type == "number" and . > 300 and . <= 86400)')"; then
      echo "nagare-registry-pull-secret: invalid or short-lived metadata access token" >&2
      exit 1
    fi
    EXPIRES_AT="$(date -u -d "@$(( $(date +%s) + LIFETIME ))" +%Y-%m-%dT%H:%M:%SZ)"

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

    for ns in ${builtins.concatStringsSep " " imagePullNamespaces}; do
      if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "nagare-registry-pull-secret: namespace $ns does not exist; skipping" >&2
        continue
      fi

      if ! EXISTING_SECRET="$(kubectl -n "$ns" get secret nagare-registry-pull --ignore-not-found -o json)"; then
        fail_or_retry "failed to inspect pull Secret in $ns"
      fi
      if [ -n "$EXISTING_SECRET" ] && ! printf '%s' "$EXISTING_SECRET" \
        | ${pkgs.jq}/bin/jq -e '.metadata.annotations["nagare.dev/delegated-owner"] == "host-registry-timer"' >/dev/null; then
        fail_or_retry "pull Secret in $ns is not owned by the host registry timer"
      fi
      WRITE_ACTION=create
      RESOURCE_VERSION=""
      if [ -n "$EXISTING_SECRET" ]; then
        WRITE_ACTION=replace
        if ! RESOURCE_VERSION="$(printf '%s' "$EXISTING_SECRET" | ${pkgs.jq}/bin/jq -er \
          '.metadata.resourceVersion | select(type == "string" and length > 0)')"; then
          fail_or_retry "pull Secret in $ns has no resource version"
        fi
      fi
      if ! EXISTING_ACCOUNT="$(kubectl -n "$ns" get serviceaccount default -o json)"; then
        fail_or_retry "failed to inspect default ServiceAccount in $ns"
      fi
      if ! printf '%s' "$EXISTING_ACCOUNT" | ${pkgs.jq}/bin/jq -e '
        ((.imagePullSecrets // []) | all(.name == "nagare-registry-pull"))
        and ((.metadata.annotations["nagare.dev/delegated-owner"] // "host-registry-timer") == "host-registry-timer")
      ' >/dev/null; then
        fail_or_retry "default ServiceAccount in $ns has a conflicting pull reference or owner"
      fi
      if ! ACCOUNT_VERSION="$(printf '%s' "$EXISTING_ACCOUNT" | ${pkgs.jq}/bin/jq -er \
        '.metadata.resourceVersion | select(type == "string" and length > 0)')"; then
        fail_or_retry "default ServiceAccount in $ns has no resource version"
      fi

      if ! kubectl -n "$ns" create secret docker-registry nagare-registry-pull \
        --docker-server="${registryHost}" \
        --docker-username=oauth2accesstoken \
        --docker-password="$TOKEN" \
        --dry-run=client -o json \
        | ${pkgs.jq}/bin/jq --arg version "${registrySourceVersion}" --arg expiry "$EXPIRES_AT" --arg rv "$RESOURCE_VERSION" \
          '(if $rv == "" then del(.metadata.resourceVersion) else .metadata.resourceVersion = $rv end)
          | .metadata.annotations = ((.metadata.annotations // {}) + {
            "nagare.dev/delegated-owner": "host-registry-timer",
            "nagare.dev/credential-source-version": $version,
            "nagare.dev/credential-expires-at": $expiry
          })' \
        | kubectl -n "$ns" "$WRITE_ACTION" -f -; then
        fail_or_retry "failed to write pull Secret in $ns"
      fi

      PATCH="$(${pkgs.jq}/bin/jq -cn --arg version "${registrySourceVersion}" --arg rv "$ACCOUNT_VERSION" \
        '{metadata:{resourceVersion:$rv,annotations:{
          "nagare.dev/delegated-owner":"host-registry-timer",
          "nagare.dev/credential-source-version":$version
        }},imagePullSecrets:[{name:"nagare-registry-pull"}]}')"
      if ! kubectl -n "$ns" patch serviceaccount default \
        --type=merge -p "$PATCH"; then
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
