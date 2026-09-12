{
  description = "NixOS host images and configurations for the Nagare personal PaaS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix }:
    let
      system = "x86_64-linux";
      nagareHostModule = {
        imports = [
          sops-nix.nixosModules.sops
          ./modules/nagare-host.nix
        ];
      };
      mkNagareSystem =
        { hostModule
        , extraModules ? [ ]
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            # Keep the GCE module in the shared system constructor so the image
            # and day-2 configurations have the same root filesystem and bootloader.
            "${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
            nagareHostModule
            hostModule
          ] ++ extraModules;
        };
      compatibilitySystem = mkNagareSystem {
        hostModule = ./hosts/nagare-01/configuration.nix;
      };
      forgeCredentialsSystem = mkNagareSystem {
        hostModule = ./hosts/nagare-01/configuration.nix;
        extraModules = [
          {
            nagare.host.forgeCredentials = {
              enable = true;
              namespace = "forge-test";
            };
          }
        ];
      };
      forgeSecretNames = builtins.filter
        (name: builtins.match "github-app/.*" name != null)
        (builtins.attrNames forgeCredentialsSystem.config.sops.secrets);
    in
    {
      lib.mkNagareSystem = mkNagareSystem;

      nixosModules.nagare-host = nagareHostModule;

      packages.${system} = {
        # Build with the FULL attribute path so aarch64-darwin dispatches to
        # the x86_64-linux remote builder:
        #   nix build .#packages.x86_64-linux.nagare-image
        # The output is config.system.build.image: a directory containing one
        # *.raw.tar.gz, exactly what `gcloud compute images create --source-uri`
        # expects.
        nagare-image = compatibilitySystem.config.system.build.image;
      };

      nixosConfigurations.nagare-01 = compatibilitySystem;

      checks.${system} = {
        # ExecPlan 115: the in-repo fixture refuses activation by any tool, an
        # operator-like configuration does not, and a configuration carrying the
        # fixture's placeholder key without the fixture flag fails to build.
        evaluation-fixture-refuses-activation =
          let
            pkgs = nixpkgs.legacyPackages.${system};
            lib = nixpkgs.lib;
            operatorLike = mkNagareSystem {
              hostModule = ./hosts/nagare-01/configuration.nix;
              extraModules = [{
                nagare.host.evaluationFixture = lib.mkForce false;
                nagare.host.authorizedKeys = lib.mkForce [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOperatorExampleKeyForChecksOnly operator-example" ];
              }];
            };
            unmarkedFixtureKey = mkNagareSystem {
              hostModule = ./hosts/nagare-01/configuration.nix;
              extraModules = [{ nagare.host.evaluationFixture = lib.mkForce false; }];
            };
            failedAssertions = sys: builtins.filter (a: !a.assertion) sys.config.assertions;
          in
          assert compatibilitySystem.config.system.preSwitchChecks ? nagareEvaluationFixture;
          assert !(operatorLike.config.system.preSwitchChecks ? nagareEvaluationFixture);
          assert failedAssertions operatorLike == [ ];
          assert failedAssertions unmarkedFixtureKey != [ ];
          pkgs.runCommand "nagare-evaluation-fixture-refuses-activation" { } ''
            set +e
            ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg compatibilitySystem.config.system.preSwitchChecks.nagareEvaluationFixture} nagare-pre-switch-check /nonexistent switch > log 2>&1
            rc=$?
            set -e
            cat log
            test "$rc" -ne 0
            grep -q "refusing to activate the in-repo evaluation fixture" log
            touch "$out"
          '';

        # ExecPlan 115: the break-glass boot menu is reachable over the serial
        # console with a real timeout and keeps older generations.
        boot-recovery-menu =
          let pkgs = nixpkgs.legacyPackages.${system}; lib = nixpkgs.lib; c = compatibilitySystem.config; in
          assert c.boot.loader.timeout == 10;
          assert lib.hasInfix "terminal_input serial" c.boot.loader.grub.extraConfig;
          assert c.boot.loader.grub.configurationLimit == 20;
          pkgs.runCommand "nagare-boot-recovery-menu" { } "touch $out";

        # ExecPlan 115: the self-reverting switch, proven by deliberately locking
        # a test host out. A good switch commits; a key-removing switch reverts by
        # itself and SSH comes back; a crash while unconfirmed boots the committed
        # generation, never the locked one.
        host-switch-auto-rollback =
          let
            pkgs = nixpkgs.legacyPackages.${system};
            lib = nixpkgs.lib;
            sshKeys = import "${nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
            # BatchMode: a rejected key must fail fast, never wait at a password prompt.
            sshOpts = "-i /root/.ssh/id_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null";
          in
          pkgs.testers.runNixOSTest {
            name = "nagare-host-switch-auto-rollback";
            nodes.host = { ... }: {
              # Boot through GRUB from the VM's own disk so a crash boots the
              # system profile's default generation, as on the real host.
              virtualisation.useBootLoader = true;
              virtualisation.installBootLoader = true;
              services.openssh = {
                enable = true;
                authorizedKeysInHomedir = false;
              };
              users.mutableUsers = false;
              users.users.deploy = {
                isNormalUser = true;
                extraGroups = [ "wheel" ];
                openssh.authorizedKeys.keys = [ sshKeys.snakeOilEd25519PublicKey ];
              };
              security.sudo.wheelNeedsPassword = false;
              nix.settings.trusted-users = [ "root" "@wheel" ];
              environment.etc."nagare-generation".text = "base";
              environment.etc."nagare/nagare-safe-activate.sh".source = ./lib/nagare-safe-activate.sh;
              specialisation.good.configuration = {
                environment.etc."nagare-generation".text = lib.mkForce "good";
              };
              specialisation.locked.configuration = {
                users.users.deploy.openssh.authorizedKeys.keys = lib.mkForce [
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly nagare-evaluation-fixture"
                ];
                environment.etc."nagare-generation".text = lib.mkForce "locked";
              };
            };
            nodes.client = { ... }: {
              environment.variables.NIX_SSHOPTS = sshOpts;
              environment.etc."nagare/nagare-safe-activate.sh".source = ./lib/nagare-safe-activate.sh;
              environment.etc."nagare/nagare-safe-switch-client.sh".source = ./lib/nagare-safe-switch-client.sh;
              environment.systemPackages = [ pkgs.openssh ];
              systemd.tmpfiles.rules = [
                "d /root/.ssh 0700 root root -"
                "C+ /root/.ssh/id_ed25519 0600 root root - ${sshKeys.snakeOilEd25519PrivateKey}"
              ];
            };
            testScript = ''
              env = "export NIX_SSHOPTS='${sshOpts}'; "

              start_all()
              host.wait_for_unit("sshd.service")
              client.wait_for_unit("multi-user.target")
              client.succeed("chmod 0600 /root/.ssh/id_ed25519")
              client.wait_until_succeeds(env + "ssh $NIX_SSHOPTS deploy@host true", timeout=60)
              good = host.succeed("readlink -f /run/current-system/specialisation/good").strip()
              locked = host.succeed("readlink -f /run/current-system/specialisation/locked").strip()
              run = env + "source /etc/nagare/nagare-safe-switch-client.sh; nagare_safe_switch deploy@host {} {} /etc/nagare/nagare-safe-activate.sh"

              # Scenario 1: a switch that keeps access commits.
              out = client.succeed(run.format(good, 120) + " 2>&1")
              print("SCENARIO 1\n" + out)
              assert "COMMITTED" in out
              host.succeed("grep -qx good /etc/nagare-generation")
              host.succeed(f"test \"$(readlink -f /nix/var/nix/profiles/system)\" = {good}")
              host.fail("systemctl is-active --quiet nagare-switch-rollback.timer")

              # Scenario 2: a switch that removes the operator key reverts by itself.
              rc, out = client.execute(run.format(locked, 150) + " 2>&1")
              print("SCENARIO 2\n" + out)
              assert rc == 4 and "NOT COMMITTED" in out, f"rc={rc}"
              client.fail(env + "ssh $NIX_SSHOPTS -o ConnectTimeout=5 deploy@host true")   # proves the lockout was real
              host.succeed("grep -qx locked /etc/nagare-generation")
              host.succeed(f"test \"$(readlink -f /nix/var/nix/profiles/system)\" = {good}")
              host.wait_until_succeeds(f"test \"$(readlink -f /run/current-system)\" = {good}", timeout=180)
              client.wait_until_succeeds(env + "ssh $NIX_SSHOPTS -o ConnectTimeout=5 deploy@host true", timeout=60)
              host.succeed("grep -qx good /etc/nagare-generation")
              host.succeed(f"test \"$(readlink -f /nix/var/nix/profiles/system)\" = {good}")
              print("SCENARIO 2 rollback journal\n" + host.succeed("journalctl -u nagare-switch-rollback.service --no-pager"))

              # Scenario 3: a crash while unconfirmed boots the committed generation.
              host.succeed(f"bash /etc/nagare/nagare-safe-activate.sh arm {locked} 600")
              host.succeed(f"bash /etc/nagare/nagare-safe-activate.sh activate {locked}")
              host.succeed("grep -qx locked /etc/nagare-generation")
              host.succeed(f"test \"$(readlink -f /nix/var/nix/profiles/system)\" = {good}")
              host.crash()
              host.start()
              host.wait_for_unit("sshd.service")
              client.wait_until_succeeds(env + "ssh $NIX_SSHOPTS -o ConnectTimeout=5 deploy@host true", timeout=120)
              print("SCENARIO 3 after crash: " + host.succeed("cat /etc/nagare-generation; readlink -f /run/current-system"))
              host.succeed("grep -qx good /etc/nagare-generation")
            '';
          };

        data-disk-auto-grow =
          let
            dataFs = compatibilitySystem.config.fileSystems."/var/lib/nagare";
            rootFs = compatibilitySystem.config.fileSystems."/";
          in
          # The data disk must grow itself when dataDiskSizeGb increases.
          assert dataFs.autoResize;
          assert builtins.elem "x-systemd.growfs" dataFs.options;
          # nofail must survive: a transient disk fault must not wedge the boot.
          assert builtins.elem "nofail" dataFs.options;
          assert dataFs.fsType == "ext4";
          # The boot disk's pre-existing auto-grow must not regress either.
          assert rootFs.autoResize;
          assert builtins.elem "x-systemd.growfs" rootFs.options;
          assert compatibilitySystem.config.boot.growPartition;
          nixpkgs.legacyPackages.${system}.runCommand "nagare-data-disk-auto-grow-check" { } ''
            touch "$out"
          '';

        forge-credentials-module =
          assert compatibilitySystem.config.nagare.host.forgeCredentials.enable == false;
          assert !(builtins.hasAttr "nagare-forge-read-refresh" compatibilitySystem.config.systemd.services);
          assert !(builtins.hasAttr "github-app/read/app-id" compatibilitySystem.config.sops.secrets);
          assert forgeCredentialsSystem.config.nagare.host.forgeCredentials.namespace == "forge-test";
          assert forgeCredentialsSystem.config.systemd.timers.nagare-forge-read-refresh.timerConfig.OnUnitActiveSec == "30min";
          assert forgeCredentialsSystem.config.systemd.timers.nagare-forge-write-refresh.timerConfig.OnUnitActiveSec == "30min";
          assert builtins.length forgeSecretNames == 6;
          assert forgeCredentialsSystem.config.sops.secrets."github-app/read/private-key".mode == "0400";
          nixpkgs.legacyPackages.${system}.runCommand "nagare-forge-credentials-module-check" { } ''
            touch "$out"
          '';
      };
    };
}
