{ config, pkgs, ... }:

let
  # The Artifact Registry Docker host the cluster pulls private images from.
  registryHost = config.nagare.host.registryHost;
  # Legacy accepted modules keep their original two-account policy. Fresh
  # typed modules opt into the exact host-owned footprint and controller grant.
  credentialOwner = config.nagare.host.registryCredentialOwner;
  controllerOwner = config.nagare.host.registryServingControllerOwner;
  imagePullTargets = [ "personal|default|" "nagare-system|default|" ]
    ++ pkgs.lib.optional (controllerOwner != "") "knative-serving|controller|${controllerOwner}";
  registrySourceVersion = builtins.hashFile "sha256" ./registries.nix;

  # The GCE metadata server caches the node token and returns the same token
  # until about five minutes of lifetime remain
  # (https://docs.cloud.google.com/compute/docs/access/authenticate-workloads),
  # so a healthy refresh may install a token with only just over 300 seconds
  # left. Every refresh must therefore finish before that minimum lifetime
  # elapses: interval + timer accuracy + run timeout < minimum lifetime. The
  # module asserts this, and unchanged tokens cause no Kubernetes write.
  minimumTokenLifetimeSec = 300;
  refreshIntervalSec = 120;
  refreshAccuracySec = 5;
  refreshTimeoutSec = 60;

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
        '.expires_in | select(type == "number" and . > ${toString minimumTokenLifetimeSec} and . <= 86400)')"; then
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

    for target in ${pkgs.lib.escapeShellArgs imagePullTargets}; do
      IFS='|' read -r ns account expected_account_owner <<< "$target"
      if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "nagare-registry-pull-secret: namespace $ns does not exist; skipping" >&2
        continue
      fi

      if ! EXISTING_SECRET="$(kubectl -n "$ns" get secret nagare-registry-pull --ignore-not-found -o json)"; then
        fail_or_retry "failed to inspect pull Secret in $ns"
      fi
      if [ -n "$EXISTING_SECRET" ] && ! printf '%s' "$EXISTING_SECRET" \
        | ${pkgs.jq}/bin/jq -e --arg owner '${credentialOwner}' '
          .metadata.annotations["nagare.dev/delegated-owner"] == "host-registry-timer"
          and ($owner == "" or .metadata.annotations["nagare.dev/resource-id"] == $owner)
        ' >/dev/null; then
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
      if ! EXISTING_ACCOUNT="$(kubectl -n "$ns" get serviceaccount "$account" -o json)"; then
        fail_or_retry "failed to inspect ServiceAccount $account in $ns"
      fi
      if ! printf '%s' "$EXISTING_ACCOUNT" | ${pkgs.jq}/bin/jq -e \
        --arg account_owner "$expected_account_owner" --arg host_owner '${credentialOwner}' '
        ((.imagePullSecrets // []) | all(.name == "nagare-registry-pull"))
        and ((.metadata.annotations["nagare.dev/delegated-owner"] // "host-registry-timer") == "host-registry-timer")
        and ($account_owner == "" or (
          .metadata.annotations["nagare.dev/resource-id"] == $account_owner
          and .metadata.annotations["nagare.dev/registry-credential-controller"] == $host_owner
        ))
      ' >/dev/null; then
        fail_or_retry "ServiceAccount $account in $ns has a conflicting pull reference, owner or grant"
      fi
      if ! ACCOUNT_VERSION="$(printf '%s' "$EXISTING_ACCOUNT" | ${pkgs.jq}/bin/jq -er \
        '.metadata.resourceVersion | select(type == "string" and length > 0)')"; then
        fail_or_retry "ServiceAccount $account in $ns has no resource version"
      fi

      if ! DESIRED_SECRET="$(kubectl -n "$ns" create secret docker-registry nagare-registry-pull \
        --docker-server="${registryHost}" \
        --docker-username=oauth2accesstoken \
        --docker-password="$TOKEN" \
        --dry-run=client -o json \
        | ${pkgs.jq}/bin/jq --arg version "${registrySourceVersion}" --arg expiry "$EXPIRES_AT" --arg rv "$RESOURCE_VERSION" --arg owner '${credentialOwner}' \
          '(if $rv == "" then del(.metadata.resourceVersion) else .metadata.resourceVersion = $rv end)
          | .metadata.annotations = ((.metadata.annotations // {}) + {
            "nagare.dev/delegated-owner": "host-registry-timer",
            "nagare.dev/credential-source-version": $version,
            "nagare.dev/credential-expires-at": $expiry
          } + (if $owner == "" then {} else {"nagare.dev/resource-id":$owner} end))')"; then
        fail_or_retry "failed to render pull Secret for $ns"
      fi
      # The same cached token needs no write; its recorded expiry is unchanged.
      # Both documents travel on stdin so the credential never enters argv.
      if [ -n "$EXISTING_SECRET" ] && printf '%s\n%s\n' "$EXISTING_SECRET" "$DESIRED_SECRET" \
        | ${pkgs.jq}/bin/jq -es '
          .[0] as $existing | .[1] as $desired
          | $existing.type == $desired.type
          and $existing.data == $desired.data
          and $existing.metadata.annotations["nagare.dev/credential-source-version"]
            == $desired.metadata.annotations["nagare.dev/credential-source-version"]
          and $existing.metadata.annotations["nagare.dev/resource-id"]
            == $desired.metadata.annotations["nagare.dev/resource-id"]
        ' >/dev/null; then
        :
      elif ! printf '%s' "$DESIRED_SECRET" | kubectl -n "$ns" "$WRITE_ACTION" -f -; then
        fail_or_retry "failed to write pull Secret in $ns"
      fi

      if printf '%s' "$EXISTING_ACCOUNT" | ${pkgs.jq}/bin/jq -e --arg version "${registrySourceVersion}" '
        .imagePullSecrets == [{"name":"nagare-registry-pull"}]
        and .metadata.annotations["nagare.dev/delegated-owner"] == "host-registry-timer"
        and .metadata.annotations["nagare.dev/credential-source-version"] == $version
      ' >/dev/null; then
        continue
      fi
      PATCH="$(${pkgs.jq}/bin/jq -cn --arg version "${registrySourceVersion}" --arg rv "$ACCOUNT_VERSION" \
        '{metadata:{resourceVersion:$rv,annotations:{
          "nagare.dev/delegated-owner":"host-registry-timer",
          "nagare.dev/credential-source-version":$version
        }},imagePullSecrets:[{name:"nagare-registry-pull"}]}')"
      if ! kubectl -n "$ns" patch serviceaccount "$account" \
        --type=merge -p "$PATCH"; then
        fail_or_retry "failed to patch ServiceAccount $account in $ns"
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
  # ready, nagare-registry-pull-secret refreshes per-pod credentials every two
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
      TimeoutStartSec = "${toString refreshTimeoutSec}s";
    };
  };

  systemd.timers.nagare-registry-pull-secret = {
    description = "Periodically refresh Kubernetes Artifact Registry pull credentials";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "${toString refreshIntervalSec}s";
      AccuracySec = "${toString refreshAccuracySec}s";
      Persistent = true;
    };
  };

  assertions = [
    {
      assertion = refreshIntervalSec + refreshAccuracySec + refreshTimeoutSec < minimumTokenLifetimeSec;
      message = "nagare registry pull Secret refresh must complete before a cached metadata token can expire";
    }
  ];
}
