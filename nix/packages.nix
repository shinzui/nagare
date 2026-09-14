{ ... }:

{
  perSystem = { pkgs, nagarePackages, ... }: {
    packages = {
      inherit (nagarePackages) nagarectl;
      nagare-platform = nagarePackages.nagarePlatform;
      net-certmanager-controller = nagarePackages.netCertManagerController;
      net-certmanager-controller-image = nagarePackages.netCertManagerControllerImage;
      nagare = nagarePackages.nagare;
      release-tools = pkgs.symlinkJoin {
        name = "nagare-release-tools";
        paths = [ pkgs.coreutils pkgs.jq ];
      };
      default = nagarePackages.nagarectl;
    };
  };
}
