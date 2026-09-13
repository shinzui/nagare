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
      scripts/check-haskell-style.sh
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
      cd "$src"
      fail=0
      for cfg in cluster/examples/*/nagare/Config.hs; do
        dir="$(dirname "$cfg")"
        echo "== compiling $cfg =="
        if ! runghc -XGHC2024 -i"$dir" "$cfg" >/dev/null; then
          echo "FAILED: $cfg" >&2
          fail=1
        fi
      done
      [ "$fail" -eq 0 ] || exit 1
      touch "$out"
    '';

  # Prove the installed wrapper loads a typed config from a directory with
  # no Nagare checkout ancestor and no Cabal-generated package environment.
  nagarectl-external-config = pkgs.runCommand "nagarectl-external-config"
    { nativeBuildInputs = [ nagarePackages.nagarectl ]; src = src; }
    ''
      mkdir -p isolated/nagare
      cp "$src/cluster/examples/hello-knative-service/nagare/Config.hs" isolated/nagare/Config.hs
      cd isolated
      unset GHC_ENVIRONMENT NAGARE_GHC_ENVIRONMENT
      nagarectl deploy --dry-run --file "$PWD/nagare/Config.hs" > output
      grep -q "kind: Service" output
      grep -q "name: hello" output

      cat > nagare/Invalid.hs <<'INVALID_CONFIG'
      module Main where

      import Nagare.Dsl.Config (emitDeployment)

      main :: IO ()
      main = emitDeployment missingDeployment
      INVALID_CONFIG
      if nagarectl deploy --dry-run --file "$PWD/nagare/Invalid.hs" \
        > invalid-output 2> invalid-error; then
        echo "invalid typed config unexpectedly succeeded" >&2
        exit 1
      fi
      grep -q "nagare: compile error" invalid-error
      if grep -Eqi 'docker|kubectl|knative' invalid-output invalid-error; then
        echo "invalid typed config reached an external deployment phase" >&2
        exit 1
      fi
      touch "$out"
    '';
}
