{ ... }:

# EP-5 (docs/plans/69, MasterPlan 13): `nix flake check` is the hermetic
# source of truth for Nagare's packages, examples, and scripts. The one
# inherited networked Cabal check for nagare-access is kept separately in
# `hydraJobs` until that executable gets its own package derivation.
#
# EP-119 formats all maintained Haskell with the pinned Fourmolu and checks
# structural house-style rules with ast-grep, so formatting drift is now a
# hermetic flake failure rather than an out-of-band convention.
{
  perSystem = { pkgs, nagarePackages, nagareSource, ... }: {
    checks =
      let src = nagareSource.src;
      in
      (import ./haskell.nix { inherit pkgs nagarePackages src; })
      // (import ./platform.nix { inherit pkgs nagarePackages src; })
      // (import ./infra.nix { inherit pkgs nagarePackages src; })
      // (import ./scripts.nix { inherit pkgs nagarePackages src; })
      // (import ./ci.nix { inherit pkgs nagarePackages src; });
  };
}
