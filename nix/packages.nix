{ pkgs, nagarePackages }:

{
  inherit (nagarePackages) nagarectl;
  nagare-platform = nagarePackages.nagarePlatform;
  nagare = nagarePackages.nagare;
  release-tools = pkgs.symlinkJoin {
    name = "nagare-release-tools";
    paths = [ pkgs.coreutils pkgs.jq ];
  };
  default = nagarePackages.nagarectl;
}
