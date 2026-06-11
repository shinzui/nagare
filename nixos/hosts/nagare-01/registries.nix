{ pkgs, ... }:

let
  # The Artifact Registry Docker host the cluster pulls private images from.
  # This is the worked-example default and mirrors the target-profile variable
  # NAGARE_REGISTRY_HOST (default us-west1-docker.pkg.dev). The NixOS flake has no
  # access to nagare.target.env at build time, so the documented default is
  # hard-coded here (consistent with how the rest of nixos/ treats project names);
  # a later cross-project change can parameterize it.
  registryHost = "us-west1-docker.pkg.dev";

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
    # k3s/containerd hot-reloads registries.yaml on change (no restart needed on
    # this k3s version; proven during the EP-2 M1 spike, 2026-06-11).
  '';
in
{
  # EP-2 (MasterPlan 13): make private-image pull DURABLE and DECLARATIVE.
  #
  # The cluster pulls application images from the project's private Artifact
  # Registry. containerd reads per-registry credentials from
  # /etc/rancher/k3s/registries.yaml; without it the pull is anonymous and AR
  # returns 403/DENIED. Rather than a hand-written token that expires in ~1 hour
  # (the non-durable fix the 2026-06-10 audit applied), this unit mints a fresh
  # token from the metadata server on boot, before k3s, and every ~30 minutes —
  # well within the token's ~1-hour lifetime — so the credential is always valid
  # with no operator action. (M1 chose this systemd-timer mechanism over the
  # kubelet credential-provider plugin because auth-provider-gcp is not packaged
  # in nixpkgs; see the EP-2 Decision Log.)
  systemd.services.nagare-registries-refresh = {
    description = "Refresh k3s Artifact Registry pull credentials from the metadata server";
    # The metadata server is link-local and available early, but require the
    # network stack so a cold boot does not race it.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Write a fresh token before k3s starts so the first pull is authenticated.
    # wantedBy (not requiredBy) so a transient metadata blip never wedges k3s.
    before = [ "k3s.service" ];
    wantedBy = [ "k3s.service" "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = refreshScript;
    };
  };

  systemd.timers.nagare-registries-refresh = {
    description = "Periodically refresh k3s Artifact Registry pull credentials";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # First refresh shortly after boot, then every 30 minutes (half the token
      # lifetime). Persistent catches up a missed firing after a stop/suspend.
      OnBootSec = "2min";
      OnUnitActiveSec = "30min";
      Persistent = true;
    };
  };
}
