{ config, lib, pkgs, ... }:

let
  cfg = config.nagare.host;
  ageKeyFile = lib.escapeShellArg cfg.ageKeyFile;
  tailscaleAuthKeyFile = lib.escapeShellArg config.sops.secrets."tailscale/authkey".path;
  hostAgeKey = pkgs.writeShellApplication {
    name = "nagare-host-age-key";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd ];
    text = ''
            set -eu

            age_key_file=${ageKeyFile}

            usage() {
              cat >&2 <<'EOF'
      Usage:
        nagare-host-age-key status
        nagare-host-age-key install --sha256 <64-lowercase-hex> [--force]

      The install command reads the age identity from stdin. Replacing a different
      installed key requires --force and is interruption-sensitive: retain both keys
      outside the host until the new encrypted secrets have been verified.
      EOF
            }

            status() {
              if [ ! -e "$age_key_file" ] && [ ! -L "$age_key_file" ]; then
                printf 'age-key\tmissing\t%s\tage key missing at %s\n' "$age_key_file" "$age_key_file"
                return 0
              fi
              if [ -L "$age_key_file" ] || [ ! -f "$age_key_file" ]; then
                printf 'age-key\tinvalid\t%s\texpected a regular file\n' "$age_key_file"
                return 0
              fi
              if [ ! -s "$age_key_file" ]; then
                printf 'age-key\tinvalid\t%s\tage key is empty\n' "$age_key_file"
                return 0
              fi

              metadata="$(stat -c '%u:%g:%a' "$age_key_file")"
              if [ "$metadata" != '0:0:400' ]; then
                printf 'age-key\tinvalid\t%s\texpected root:root mode 0400; found %s\n' "$age_key_file" "$metadata"
                return 0
              fi

              digest="$(sha256sum "$age_key_file")"
              digest="''${digest%% *}"
              printf 'age-key\tready\t%s\t%s\n' "$age_key_file" "$digest"
            }

            activate() {
              systemctl restart sops-install-secrets.service
              if [ ! -s ${tailscaleAuthKeyFile} ]; then
                echo "nagare-host-age-key: decrypted Tailscale auth key is missing or empty" >&2
                exit 1
              fi
              systemctl restart tailscaled-autoconnect.service
            }

            install_key() {
              expected=""
              force=0
              while [ "$#" -gt 0 ]; do
                case "$1" in
                  --sha256)
                    [ "$#" -ge 2 ] || { usage; exit 2; }
                    expected="$2"
                    shift 2
                    ;;
                  --force)
                    force=1
                    shift
                    ;;
                  *)
                    usage
                    exit 2
                    ;;
                esac
              done

              if [ "$(id -u)" -ne 0 ]; then
                echo "nagare-host-age-key: install must run as root" >&2
                exit 1
              fi
              if [ -z "$expected" ]; then
                echo "nagare-host-age-key: --sha256 must be 64 lowercase hexadecimal characters" >&2
                exit 2
              fi
              case "$expected" in
                *[!0-9a-f]*)
                  echo "nagare-host-age-key: --sha256 must be 64 lowercase hexadecimal characters" >&2
                  exit 2
                  ;;
              esac
              if [ "''${#expected}" -ne 64 ]; then
                echo "nagare-host-age-key: --sha256 must be 64 lowercase hexadecimal characters" >&2
                exit 2
              fi

              parent="$(dirname "$age_key_file")"
              install -d -o root -g root -m 0700 "$parent"

              write_key=1
              if [ -e "$age_key_file" ] || [ -L "$age_key_file" ]; then
                if [ -L "$age_key_file" ] || [ ! -f "$age_key_file" ]; then
                  echo "nagare-host-age-key: refusing to replace a non-regular key path: $age_key_file" >&2
                  exit 1
                fi
                existing="$(sha256sum "$age_key_file")"
                existing="''${existing%% *}"
                if [ "$existing" = "$expected" ]; then
                  write_key=0
                  chown root:root "$age_key_file"
                  chmod 0400 "$age_key_file"
                elif [ "$force" -ne 1 ]; then
                  echo "nagare-host-age-key: a different key is already installed; rerun with --force only after preserving both keys" >&2
                  exit 1
                fi
              fi

              writing=0
              verified=0
              cleanup_partial() {
                if [ "$writing" -eq 1 ] && [ "$verified" -eq 0 ]; then
                  rm -f -- "$age_key_file"
                fi
              }
              trap cleanup_partial EXIT
              trap 'exit 130' HUP INT TERM

              if [ "$write_key" -eq 1 ]; then
                writing=1
                install -o root -g root -m 0400 /dev/stdin "$age_key_file"
                actual="$(sha256sum "$age_key_file")"
                actual="''${actual%% *}"
                if [ "$actual" != "$expected" ]; then
                  echo "nagare-host-age-key: checksum mismatch; partial key removed, retry placement" >&2
                  exit 1
                fi
              else
                actual="$expected"
              fi

              installed_metadata="$(stat -c '%u:%g:%a' "$age_key_file")"
              if [ "$installed_metadata" != '0:0:400' ]; then
                echo "nagare-host-age-key: installed key metadata verification failed: expected root:root mode 0400; found $installed_metadata" >&2
                exit 1
              fi
              verified=1
              writing=0

              activate
              printf 'age key ready at %s (sha256 %s); secrets activated and Tailscale autoconnect started\n' "$age_key_file" "$actual"
            }

            case "''${1:-}" in
              status)
                [ "$#" -eq 1 ] || { usage; exit 2; }
                status
                ;;
              install)
                shift
                install_key "$@"
                ;;
              *)
                usage
                exit 2
                ;;
            esac
    '';
  };
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
    ../hosts/nagare-01/boot-recovery.nix
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
      {
        assertion = lib.hasPrefix "/" cfg.ageKeyFile
          && !(lib.hasInfix "\n" cfg.ageKeyFile)
          && !(lib.hasInfix "\t" cfg.ageKeyFile);
        message = "nagare.host.ageKeyFile must be an absolute path without tabs or newlines";
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
    sops.useSystemdActivation = true;
    sops.secrets."tailscale/authkey" = {
      mode = "0400";
    };

    environment.systemPackages = [ hostAgeKey ];

    systemd.services.tailscaled-autoconnect = {
      after = [ "sops-install-secrets.service" ];
      preStart = lib.mkBefore ''
        if [ ! -e ${ageKeyFile} ] && [ ! -L ${ageKeyFile} ]; then
          echo "age key missing at ${cfg.ageKeyFile}" >&2
          exit 1
        fi
        if [ -L ${ageKeyFile} ] || [ ! -f ${ageKeyFile} ] || [ ! -s ${ageKeyFile} ]; then
          echo "age key invalid at ${cfg.ageKeyFile}: expected a non-empty regular file" >&2
          exit 1
        fi
        if [ "$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' ${ageKeyFile})" != '0:0:400' ]; then
          echo "age key invalid at ${cfg.ageKeyFile}: expected root:root mode 0400" >&2
          exit 1
        fi
        if [ ! -s ${tailscaleAuthKeyFile} ]; then
          echo "decrypted Tailscale auth key missing at ${config.sops.secrets."tailscale/authkey".path}" >&2
          exit 1
        fi
      '';
    };
  };
}
