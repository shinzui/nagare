{ inputs, releaseVersion, sourceRevision, ... }:

{
  perSystem = { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
      nagareSource = import ./source.nix {
        inherit (inputs.nixpkgs) lib;
        root = ../.;
      };
      platformPackage = import ./platform-package.nix {
        inherit pkgs releaseVersion sourceRevision;
        inherit (nagareSource) isNixWiring;
        sourceRoot = ../.;
      };
      nagarePackages = import ./haskell-packages.nix {
        inherit pkgs platformPackage sourceRevision;
        cradleSrc = inputs.cradle;
      };
    in
    {
      _module.args = { inherit pkgs nagarePackages nagareSource; };
    };
}
