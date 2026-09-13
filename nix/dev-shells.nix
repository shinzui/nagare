{ inputs, ... }:

{
  perSystem = { pkgs, system, ... }:
    let
      mkDevShell = inputs.haskell-nix-dev.lib.${system}.mkDevShell;
      haskellTools = [
        pkgs.haskell.packages.ghc9124.fourmolu
        pkgs.haskell.packages.ghc9124.cabal-gild
        pkgs.ast-grep
        pkgs.postgresql
        # k3d keeps local-mode development available in either shell.
        pkgs.k3d
      ];
    in
    {
      devShells = {
        default = mkDevShell {
          ghc = "ghc9124";
          withHls = true;
          extraNativeBuildInputs = [
            # Pulumi (provisioning) — Integration Point 8 / EP-2.
            pkgs.pulumi
            pkgs.pulumiPackages.pulumi-nodejs
            # nodejs_22 is the current active LTS. The plan originally
            # pinned nodejs_20, but that release is now insecure (EOL).
            pkgs.nodejs_22
            pkgs.typescript
            # Google Cloud SDK provides both `gcloud` and `gsutil`.
            pkgs.google-cloud-sdk
            # Work around the macOS OpenSSH 10.x / gcloud IAP tunnel bug.
            pkgs.socat
            pkgs.kubectl
            pkgs.kubernetes-helm
            pkgs.sops
            pkgs.age
            pkgs.tailscale
            pkgs.jq
            pkgs.just
          ] ++ haskellTools;
          shellHook = ''
            export PULUMI_HOME="''${PWD}/infra/pulumi/.pulumi-home"
          '';
        };

        # Haskell-focused shell without HLS. GHC, cabal-install, pkg-config,
        # and zlib still come from the shared toolchain helper.
        haskell = mkDevShell {
          ghc = "ghc9124";
          withHls = false;
          extraNativeBuildInputs = haskellTools;
        };
      };
    };
}
