{ ... }:

{
  perSystem = { pkgs, lib, system, nagarePackages, ... }: {
    packages = {
      inherit (nagarePackages) nagarectl;
      attic-client = nagarePackages.atticClient;
      attic-server-image = nagarePackages.atticServerImage;
      nagare-platform = nagarePackages.nagarePlatform;
      net-certmanager-controller = nagarePackages.netCertManagerController;
      net-certmanager-controller-image = nagarePackages.netCertManagerControllerImage;
      nagare = nagarePackages.nagare;
      nagare-harness = nagarePackages.nagareHarness;
      release-tools = pkgs.symlinkJoin {
        name = "nagare-release-tools";
        paths = [ pkgs.coreutils pkgs.jq pkgs.python3 ];
      };
      default = nagarePackages.nagarectl;
    } // lib.optionalAttrs (system == "x86_64-linux") {
      # EP-237: the release service images, their manifest, and the check
      # that root release.json carries that manifest.
      release-image-en = nagarePackages.releaseImages.layouts.en;
      release-image-shomei = nagarePackages.releaseImages.layouts.shomei;
      release-image-access = nagarePackages.releaseImages.layouts.nagare-access;
      release-image-admin-api = nagarePackages.releaseImages.layouts.nagare-admin-api;
      release-image-cloudflared = nagarePackages.releaseImages.layouts.cloudflared;
      release-images-manifest = nagarePackages.releaseImages.manifest;
      release-images-check = nagarePackages.releaseImages.check;
    };
  };
}
