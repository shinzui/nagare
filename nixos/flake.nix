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
    in {
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
    };
}
