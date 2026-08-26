{ config, lib, pkgs, ... }:

let
  cfg = config.nagare.host.forgeCredentials;

  roles = [ "read" "write" ];

  secretPath = role: field: "github-app/${role}/${field}";
  kubernetesSecretName = role: "nagare-forge-${role}";
  unitName = role: "nagare-forge-${role}-refresh";

  refreshProgram = pkgs.writeShellApplication {
    name = "nagare-forge-refresh";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.openssl
      config.services.k3s.package
    ];
    text = builtins.readFile ./forge-credentials-refresh.sh;
  };

  mkService = role: {
    description = "Refresh the ${role} GitHub App installation token in Kubernetes";
    after = [ "network-online.target" "k3s.service" ];
    wants = [ "network-online.target" "k3s.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.escapeShellArgs [
        (lib.getExe refreshProgram)
        role
        config.sops.secrets.${secretPath role "app-id"}.path
        config.sops.secrets.${secretPath role "installation-id"}.path
        config.sops.secrets.${secretPath role "private-key"}.path
        (kubernetesSecretName role)
        cfg.namespace
      ];
      RuntimeDirectory = unitName role;
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
    };
  };

  mkTimer = role: {
    description = "Periodically refresh the ${role} GitHub App installation token";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "30min";
      RandomizedDelaySec = "2min";
      Persistent = true;
    };
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.namespace != "";
        message = "nagare.host.forgeCredentials.namespace must not be empty";
      }
    ];

    sops.secrets = lib.listToAttrs (
      lib.concatMap
        (role:
          map
            (field: {
              name = secretPath role field;
              value = {
                owner = "root";
                group = "root";
                mode = "0400";
              };
            })
            [ "app-id" "installation-id" "private-key" ])
        roles
    );

    systemd.services = lib.listToAttrs (
      map
        (role: {
          name = unitName role;
          value = mkService role;
        })
        roles
    );

    systemd.timers = lib.listToAttrs (
      map
        (role: {
          name = unitName role;
          value = mkTimer role;
        })
        roles
    );
  };
}
