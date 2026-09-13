{
  description = "nagare developer shell (project-pinned Pulumi + Haskell + cloud toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-parts = {
    url = "github:hercules-ci/flake-parts/31729ca8cbdb4fa927b34e5f4353e6a83f39e993";
    inputs.nixpkgs-lib.follows = "nixpkgs";
  };
  inputs.cradle = {
    url = "github:garnix-io/cradle/711c441fa8f190a8964c56a3bae864cd5321c5c5";
    flake = false;
  };

  outputs = inputs@{ self, flake-parts, ... }:
    let
      releaseMetadata = builtins.fromJSON (builtins.readFile ./release.json);
      releaseVersion = releaseMetadata.platformVersion;
      sourceRevision =
        if self ? rev then self.rev
        else if self ? dirtyRev then self.dirtyRev
        else null;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = releaseMetadata.supportedSystems;
      imports = [
        ./nix/nagare-packages.nix
        ./nix/packages.nix
        ./nix/apps.nix
        ./nix/checks/default.nix
        ./nix/hydra-jobs.nix
        ./nix/dev-shells.nix
      ];
      _module.args = { inherit releaseVersion sourceRevision; };
      flake.lib.release = {
        version = releaseVersion;
        inherit sourceRevision;
        supportedSystems = releaseMetadata.supportedSystems;
      };
    };
}
