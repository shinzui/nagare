{ inputs, releaseVersion, sourceRevision, ... }:

{
  perSystem = { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
      nagareSource = import ./source.nix {
        inherit (inputs.nixpkgs) lib;
        root = ../.;
      };
      netCertManager = import ./net-certmanager-controller.nix { inherit pkgs; };
      attic = import ./attic.nix {
        inherit pkgs;
        atticClient = inputs.attic.packages.${system}.attic-client;
      };
      platformPackage = import ./platform-package.nix {
        inherit pkgs releaseVersion sourceRevision;
        inherit (nagareSource) isNixWiring;
        netCertManagerImage = netCertManager.image;
        netCertManagerImageReference = netCertManager.imageReference;
        atticServerImage = attic.serverImage;
        atticPinFile = attic.pinFile;
        sourceRoot = ../.;
      };
      haskellPackages = import ./haskell-packages.nix {
        inherit pkgs platformPackage sourceRevision;
        atticClient = attic.client;
        cradleSrc = inputs.cradle;
      };
      nagarePackages = haskellPackages // {
        netCertManagerController = netCertManager.controller;
        netCertManagerControllerImage = netCertManager.image;
        netCertManagerControllerImageReference = netCertManager.imageReference;
        atticClient = attic.client;
        atticServerImage = attic.serverImage;
        atticPin = attic.pin;
        atticPinFile = attic.pinFile;
      };
    in
    {
      _module.args = { inherit pkgs nagarePackages nagareSource; };
    };
}
