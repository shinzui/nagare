{ ... }:

{
  perSystem = { pkgs, ... }:
    let pulumi = import ./pulumi.nix { inherit pkgs; };
    in
    {
      devShells = {
    default = pkgs.mkShell {
      name = "nagare";
      packages = [
        # Pulumi (provisioning) — Integration Point 8 / EP-2.
        pulumi.pulumi
        pulumi.pulumi-nodejs
        # nodejs_22 is the current active LTS. The plan originally
        # pinned nodejs_20, but the nixos-unstable channel now marks
        # that release insecure (EOL), which refuses to evaluate; see
        # the Decision Log and Surprises & Discoveries in EP-1.
        pkgs.nodejs_22
        pkgs.typescript
        # Google Cloud SDK provides both `gcloud` and `gsutil` — EP-2/3/4/7.
        pkgs.google-cloud-sdk
        # socat: ssh ProxyCommand for IAP tunnels, working around the
        # macOS OpenSSH 10.x <-> gcloud --tunnel-through-iap bug noted
        # in the reference repo. — EP-2/EP-3.
        pkgs.socat
        # Kubernetes + Helm clients — EP-4/EP-5/EP-6.
        pkgs.kubectl
        pkgs.kubernetes-helm
        # k3d runs k3s inside Docker for local-mode development — EP-82
        # (MasterPlan 16). `just local-up` uses it to stand up the local
        # cluster + registry; needs a running Docker daemon.
        pkgs.k3d
        # Secret encryption — EP-3/EP-7.
        pkgs.sops
        pkgs.age
        # Private network access to the host — EP-3.
        pkgs.tailscale
        # JSON wrangling in scripts — used across plans.
        pkgs.jq
        # The command runner that reads ./justfile.
        pkgs.just
        # Haskell toolchain pinned to GHC 9.12 (house standard;
        # see haskell-jitsurei/core/standards.md). Pattern mirrors
        # bokuno/nix/nix-flake-templates/haskell-9_12/flake.nix.
        # Originally EP-6's unpinned pkgs.ghc (~9.10); re-pinned to
        # 9.12 by EP-8 M0 (MasterPlan 2, Integration Point 6) so the
        # nagare-dsl initiative inherits the house toolchain. GHC's
        # closure is large (multiple GB); see the optional split below.
        pkgs.haskell.compiler.ghc912
        pkgs.cabal-install
        pkgs.haskell.packages.ghc912.haskell-language-server
        pkgs.haskell.packages.ghc912.fourmolu
        pkgs.haskell.packages.ghc912.cabal-gild
        pkgs.ast-grep
        pkgs.zlib
        pkgs.postgresql
        pkgs.pkg-config
      ];
      shellHook = ''
        export PULUMI_HOME="''${PWD}/infra/pulumi/.pulumi-home"
      '';
    };

    # OPTIONAL lighter shell without the Haskell compiler, for readers
    # who do not need to build nagarectl and want a smaller download.
    # Enter it with `nix develop .#haskell`-style targets reversed:
    # this one is `nix develop` minus GHC. Kept here as documentation
    # of the split option from the Decision Log; safe to delete if
    # unused.
    haskell = pkgs.mkShell {
      name = "nagare-haskell";
      packages = [
        pkgs.haskell.compiler.ghc912
        pkgs.cabal-install
        pkgs.haskell.packages.ghc912.fourmolu
        pkgs.haskell.packages.ghc912.cabal-gild
        pkgs.ast-grep
        pkgs.zlib
        pkgs.postgresql
        pkgs.pkg-config
        # k3d for local-mode development parity with the default shell — EP-82.
        pkgs.k3d
      ];
    };
      };
    };
}
