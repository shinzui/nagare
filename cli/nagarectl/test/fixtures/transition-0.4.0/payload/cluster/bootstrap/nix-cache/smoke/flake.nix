{
  description = "Deterministic Nagare Attic substitution smoke path";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/9b008d60392981ad674e04016d25619281550a9d";

  outputs = { nixpkgs, ... }:
    let
      forSystem = system: nixpkgs.legacyPackages.${system}.writeText "nagare-attic-smoke" ''
        nagare-attic-smoke-v1
      '';
      # Every operator system resolves the same Linux derivation that the
      # x86_64 cluster Pod requests. A non-Linux operator uses its configured
      # remote builder rather than accidentally pushing a Darwin-only path.
      linuxSmoke = forSystem "x86_64-linux";
    in
    {
      packages.x86_64-linux.default = linuxSmoke;
      packages.aarch64-linux.default = linuxSmoke;
      packages.aarch64-darwin.default = linuxSmoke;
      packages.x86_64-darwin.default = linuxSmoke;
    };
}
