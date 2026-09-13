{ pkgs, nagarePackages, src }:

{
  # Build and test the typed DSL and CLI through the hermetic package set.
  nagare-dsl-build-test = nagarePackages.checkedNagareDsl;
  nagarectl-build-test = nagarePackages.checkedNagarectl;

  haskell-style = pkgs.runCommand "haskell-style"
    {
      nativeBuildInputs = [
        pkgs.ast-grep
        pkgs.bash
        pkgs.coreutils
        pkgs.findutils
        pkgs.ripgrep
        pkgs.haskell.packages.ghc9124.fourmolu
        pkgs.haskell.packages.ghc9124.cabal-gild
      ];
      src = src;
    }
    ''
      cd "$src"
      bash scripts/check-haskell-style.sh
      find cli -type f -name '*.hs' -print0 \
        | sort -z \
        | xargs -0 fourmolu --mode check --config cli/fourmolu.yaml \
            --ghc-opt=-XImportQualifiedPost
      cabal-gild --mode check --input cli/nagare-dsl/nagare-dsl.cabal
      cabal-gild --mode check --input cli/nagarectl/nagarectl.cabal
      cabal-gild --mode check --input cli/nagare-access/nagare-access.cabal
      touch "$out"
    '';
  # Compile-and-run every shipped cluster/examples/*/nagare/Config.hs through
  # the same packaged runghc runtime used by the installed CLI.
  examples-compile = pkgs.runCommand "examples-compile"
    { nativeBuildInputs = [ nagarePackages.typedConfigRuntime ]; src = src; }
    ''
      bash ${./scripts/examples-compile.sh}
    '';

  # Prove the installed wrapper loads a typed config from a directory with
  # no Nagare checkout ancestor and no Cabal-generated package environment.
  nagarectl-external-config = pkgs.runCommand "nagarectl-external-config"
    { nativeBuildInputs = [ nagarePackages.nagarectl ]; src = src; }
    ''
      bash ${./scripts/nagarectl-external-config.sh}
    '';
}
