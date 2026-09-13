{
  description = "nagare developer shell (project-pinned Pulumi + Haskell + cloud toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.cradle = {
    url = "github:garnix-io/cradle/711c441fa8f190a8964c56a3bae864cd5321c5c5";
    flake = false;
  };

  outputs = { self, nixpkgs, cradle }:
    let
      releaseMetadata = builtins.fromJSON (builtins.readFile ./release.json);
      releaseVersion = releaseMetadata.platformVersion;
      systems = releaseMetadata.supportedSystems;
      sourceRevision =
        if self ? rev then self.rev
        else if self ? dirtyRev then self.dirtyRev
        else null;
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));
      nagareSource = import ./nix/source.nix {
        inherit (nixpkgs) lib;
        root = ./.;
      };
      nagarePackagesFor = pkgs: import ./nix/nagare-packages.nix {
        inherit pkgs nagareSource releaseVersion sourceRevision cradle;
      };
    in
    {
      lib.release = {
        version = releaseVersion;
        inherit sourceRevision;
        supportedSystems = systems;
      };

      packages = forAllSystems (pkgs:
        import ./nix/packages.nix {
          inherit pkgs;
          nagarePackages = nagarePackagesFor pkgs;
        });

      apps = forAllSystems (pkgs:
        import ./nix/apps.nix {
          nagarePackages = nagarePackagesFor pkgs;
        });

      checks = forAllSystems (pkgs:
        import ./nix/checks/default.nix {
          inherit pkgs;
          nagarePackages = nagarePackagesFor pkgs;
          src = nagareSource.src;
        });

      hydraJobs = forAllSystems (pkgs:
        import ./nix/hydra-jobs.nix {
          inherit pkgs;
          src = nagareSource.src;
        });

      devShells = forAllSystems (pkgs:
        import ./nix/dev-shells.nix {
          inherit pkgs;
          pulumi = import ./nix/pulumi.nix { inherit pkgs; };
        });
    };
}
