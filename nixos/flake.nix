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

      # The module set that defines `nagare-01`. It INCLUDES the upstream
      # GCE module so the resulting system is bootable on Compute Engine
      # (root filesystem + grub come from google-compute-config.nix, which
      # google-compute-image.nix imports). Used in two places, from the SAME
      # list so the two never drift:
      #   * mkSystem -> config.system.build.image: the GCE image
      #     (a directory containing one *.raw.tar.gz).
      #   * nixosConfigurations.nagare-01: the day-2 `nixos-rebuild --flake
      #     .#nagare-01 --target-host nagare-01` target. Because the GCE module
      #     is in this shared list, the rebuild target has a root fs + bootloader
      #     and matches exactly what was baked into the image.
      #
      # NOTE: the GCE module must be in this shared set, not added only in the
      # image path. If it is image-only, `nixosConfigurations.nagare-01` fails
      # to evaluate ("fileSystems option does not specify your root file system"
      # / "boot.loader.grub.devices") and the day-2 path is broken. The upstream
      # reference repo only builds images and never hit this, so the plan's
      # original image-only placement was wrong here; see the Decision Log.
      nagare01Modules = [
        "${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
        ./configuration-base.nix
        sops-nix.nixosModules.sops
        ./hosts/nagare-01/configuration.nix
      ];

      mkSystem = modules:
        nixpkgs.lib.nixosSystem { inherit system; inherit modules; };
    in {
      packages.${system} = {
        # Build with the FULL attribute path so aarch64-darwin dispatches to
        # the x86_64-linux remote builder:
        #   nix build .#packages.x86_64-linux.nagare-image
        # The output is config.system.build.image: a directory containing one
        # *.raw.tar.gz, exactly what `gcloud compute images create --source-uri`
        # expects.
        nagare-image = (mkSystem nagare01Modules).config.system.build.image;
      };

      nixosConfigurations.nagare-01 = mkSystem nagare01Modules;
    };
}
