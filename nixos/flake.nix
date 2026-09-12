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
