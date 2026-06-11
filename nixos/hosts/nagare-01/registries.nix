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
    # NOTE: k3s reads registries.yaml only at START — it bakes the credential into
    # containerd's generated config; the running containerd does NOT hot-reload a
    # rewritten registries.yaml. So writing a fresh token here is necessary but not
    # sufficient: containerd keeps using the token loaded at the last k3s start.
    # The 'nagare-registries-reload' service below restarts k3s on a timer so the
    # fresh token actually takes effect (this service re-runs before each restart).
    # (Discovered by EP-5's live smoke test, 2026-06-11; see the EP-2 Decision Log.)
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
  # written on boot (before k3s) and refreshed on a timer.
  #
  # The credential is durable via TWO cooperating units, because k3s only loads
  # registries.yaml at start (the running containerd ignores later rewrites):
  #   * nagare-registries-refresh — writes a fresh token; runs before k3s, so every
  #     k3s (re)start picks up a fresh credential.
  #   * nagare-registries-reload  — a timer-driven `systemctl restart k3s`, so the
  #     refreshed token actually reaches containerd. It is deliberately NOT a k3s
  #     dependency, to avoid an ordering cycle with the refresh service.
  # A k3s SERVER restart briefly interrupts the control plane (~15-30s) but does
  # NOT stop running workload pods (containerd keeps them), so app traffic is
  # uninterrupted. (The kubelet image-credential-provider plugin would avoid the
  # restart entirely by minting per-pull, but auth-provider-gcp is not packaged in
  # nixpkgs — see the EP-2 Decision Log; packaging it is the recommended follow-up.)
  systemd.services.nagare-registries-refresh = {
    description = "Refresh k3s Artifact Registry pull credentials from the metadata server";
    # The metadata server is link-local and available early, but require the
    # network stack so a cold boot does not race it.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Write a fresh token before k3s starts so the first pull (and every pull after
    # a reload-triggered restart) is authenticated. wantedBy (not requiredBy) so a
    # transient metadata blip never wedges k3s.
    before = [ "k3s.service" ];
    wantedBy = [ "k3s.service" "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = refreshScript;
    };
  };

  # Restart k3s so containerd reloads the refreshed registries.yaml token. Starting
  # k3s re-runs nagare-registries-refresh (its Before/WantedBy), writing a fresh
  # token first. This unit is intentionally NOT WantedBy/Before k3s, so there is no
  # ordering cycle.
  systemd.services.nagare-registries-reload = {
    description = "Restart k3s so containerd reloads the refreshed Artifact Registry token";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart k3s.service";
    };
  };

  systemd.timers.nagare-registries-reload = {
    description = "Periodically reload k3s registry credentials (restart k3s with a fresh token)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # The boot-time token (written before k3s) is valid ~1 hour; restart every 45
      # minutes so the token containerd holds is always < 45 min old (safely within
      # its ~1h lifetime). Persistent catches up a missed firing after suspend.
      OnBootSec = "45min";
      OnUnitActiveSec = "45min";
      Persistent = true;
    };
  };
}
