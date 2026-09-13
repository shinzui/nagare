{ pkgs, nagareSource, releaseVersion, sourceRevision, cradle }:

let
  platformPackage = import ./platform-package.nix {
    inherit pkgs releaseVersion sourceRevision;
    inherit (nagareSource) isNixWiring;
    sourceRoot = ../.;
  };
in
import ./haskell-packages.nix {
  inherit pkgs platformPackage sourceRevision;
  cradleSrc = cradle;
}
