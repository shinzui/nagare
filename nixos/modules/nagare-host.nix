{ config, lib, ... }:

let
  cfg = config.nagare.host;
in
{
  imports = [
    ../configuration-base.nix
    ../hosts/nagare-01/networking.nix
    ../hosts/nagare-01/storage.nix
    ../hosts/nagare-01/users.nix
    ../hosts/nagare-01/security.nix
    ../hosts/nagare-01/k3s.nix
    ../hosts/nagare-01/tailscale.nix
    ../hosts/nagare-01/registries.nix
    ../hosts/nagare-01/forge-credentials.nix
  ];

  options.nagare.host = {
    evaluationFixture = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Marks the in-repository evaluation fixture. A fixture configuration refuses activation
        through a pre-switch check, so it can be evaluated and built but never switched onto a host.
      '';
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      description = "NixOS host name for this Nagare node.";
    };

    instanceName = lib.mkOption {
      type = lib.types.str;
      description = "Cloud instance identity associated with this Nagare node.";
    };

    registryHost = lib.mkOption {
      type = lib.types.str;
      description = "Artifact Registry host used for private application images.";
    };

    deployUser = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = "Operator account created on the host.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys authorized for the operator account.";
    };

    sopsDefaultFile = lib.mkOption {
      type = lib.types.path;
      description = "Encrypted sops file containing the host's declared secrets.";
    };

    ageKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sops-nix/age-key.txt";
      description = "On-host path to the age private key used by sops-nix.";
    };

    forgeCredentials = {
      enable = lib.mkEnableOption "rotating GitHub App credentials for runtime workloads";

      namespace = lib.mkOption {
        type = lib.types.str;
        default = "personal";
        description = "Kubernetes namespace in which to publish the role-named forge Secrets.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ];
        message = "nagare.host.authorizedKeys must contain at least one operator SSH public key";
      }
      {
        assertion = cfg.evaluationFixture
          || !(lib.any (key: lib.hasInfix "FixtureKeyForNagareEvaluationOnly" key) cfg.authorizedKeys);
        message = "nagare.host.authorizedKeys contains the evaluation-fixture placeholder key; a real host would lock its operator out";
      }
      {
        assertion = cfg.hostName != "";
        message = "nagare.host.hostName must not be empty";
      }
      {
        assertion = cfg.instanceName != "";
        message = "nagare.host.instanceName must not be empty";
      }
      {
        assertion = cfg.registryHost != "";
        message = "nagare.host.registryHost must not be empty";
      }
    ];

    # ExecPlan 115 / ADR 11: the fixture's "do not deploy" status lives in the configuration
    # itself. switch-to-configuration runs this before changing anything, for every tool.
    system.preSwitchChecks.nagareEvaluationFixture = lib.mkIf cfg.evaluationFixture ''
      echo "nagare: refusing to activate the in-repo evaluation fixture (nixos#${cfg.hostName}). Use 'just host-switch' with the context-owned host flake." >&2
      exit 1
    '';

    networking.hostName = cfg.hostName;

    sops.defaultSopsFile = cfg.sopsDefaultFile;
    sops.age.keyFile = cfg.ageKeyFile;
    sops.secrets."tailscale/authkey" = {
      mode = "0400";
    };
  };
}
