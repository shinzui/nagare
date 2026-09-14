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
      platformPackage = import ./platform-package.nix {
        inherit pkgs releaseVersion sourceRevision;
        inherit (nagareSource) isNixWiring;
        netCertManagerImage = netCertManager.image;
        netCertManagerImageReference = netCertManager.imageReference;
        sourceRoot = ../.;
      };
      haskellPackages = import ./haskell-packages.nix {
        inherit pkgs platformPackage sourceRevision;
        cradleSrc = inputs.cradle;
      };
      nagarePackages = haskellPackages // {
        netCertManagerController = netCertManager.controller;
        netCertManagerControllerImage = netCertManager.image;
        netCertManagerControllerImageReference = netCertManager.imageReference;
      };
    in
    {
      _module.args = { inherit pkgs nagarePackages nagareSource; };
    };
}
