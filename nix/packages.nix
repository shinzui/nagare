{ ... }:

{
  perSystem = { pkgs, nagarePackages, ... }: {
    packages = {
      inherit (nagarePackages) nagarectl;
      attic-client = nagarePackages.atticClient;
      attic-server-image = nagarePackages.atticServerImage;
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
