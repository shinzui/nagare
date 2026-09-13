{
  description = "nagare developer shell (project-pinned Pulumi + Haskell + cloud toolchain)";

  inputs.haskell-nix-dev = {
    url = "github:shinzui/haskell-nix-dev/206ecd25bcb4a07581210bdae3e6f43c8fd179d8";
    inputs.treefmt-nix.inputs.nixpkgs.follows = "haskell-nix-dev/nixpkgs";
  };
  inputs.nixpkgs.follows = "haskell-nix-dev/nixpkgs";
  inputs.flake-parts.follows = "haskell-nix-dev/flake-parts";
  inputs.cradle = {
    url = "github:garnix-io/cradle/711c441fa8f190a8964c56a3bae864cd5321c5c5";
    flake = false;
  };

  nixConfig = {
    extra-substituters = [ "https://shinzui.cachix.org" ];
    extra-trusted-public-keys = [ "shinzui.cachix.org-1:QEmAoJrA9WwLP0uxfDgktLi2BRrcvQQWdz8NzcMg4/E=" ];
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
