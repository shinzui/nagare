{ config, lib, pkgs, ... }:

let
  cfg = config.services.gcp;
in {
  options.services.gcp = {
    enable = lib.mkEnableOption "GCE compatibility (guest agent, IAP-friendly sshd, baseline sysctls)";

    user.name = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = ''
        Name of the optional break-glass Linux user created when
        `services.gcp.user.sshAuthorizedKeys` is non-empty. Normal logins use
        OS Login (IAP) or the deploy user defined in hosts/nagare-01/users.nix.
      '';
    };

    user.sshAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Public SSH keys appended to the break-glass user's authorized_keys.
        Empty (the default) creates no extra user.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # services.openssh.enable, security.googleOsLogin.enable, and the
    # google-guest-agent unit are set by the upstream GCE config module the
    # image format imports. We only tighten sshd here. Do NOT set
    # ListenAddress/AllowUsers — IAP arrives on the VM's primary internal IP.
    services.openssh.settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };

    services.chrony.enable = true;

    boot.kernel.sysctl = {
      "vm.swappiness" = 10;
      "net.ipv4.tcp_keepalive_time" = 60;
      "kernel.unprivileged_bpf_disabled" = 1;
      "kernel.kptr_restrict" = 2;
    };

    services.journald.extraConfig = ''
      SystemMaxUse=500M
      MaxRetentionSec=7day
    '';

    users.users = lib.mkIf (cfg.user.sshAuthorizedKeys != [ ]) {
      ${cfg.user.name} = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = cfg.user.sshAuthorizedKeys;
      };
    };

    security.sudo.wheelNeedsPassword = false;
  };
}
