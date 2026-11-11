{ inputs, lib, releaseSystems, releaseVersion, sourceRevision, ... }:

{
  perSystem = { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
      # A release system receives every platform output. A tooling-only system
      # (ADR 3) receives the packaged CLI, its configuration SDK and the SDK
      # consumer check, with a deploy payload: the platform payload without the
      # bootstrap image archives, because every deploy prepares the platform
      # workspace and a delegated deployer runs on ARM64 too (EP-248).
      isReleaseSystem = lib.elem system releaseSystems;
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
        includeBootstrapImages = isReleaseSystem;
      };
      haskellPackages = import ./haskell-packages.nix {
        inherit pkgs releaseVersion sourceRevision;
        inherit platformPackage;
        atticClient = attic.client;
        cradleSrc = inputs.cradle;
        gogolSrc = inputs.gogol;
      };
      # EP-237: the release service images exist only for x86_64-linux.
      releaseImages = import ./release-images.nix {
        inherit pkgs;
        platformHaskellPackages = haskellPackages.haskellPackages;
      };
      nagarePackages = haskellPackages // {
        inherit releaseImages;
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
      _module.args = { inherit isReleaseSystem pkgs nagarePackages nagareSource; };
    };
}
