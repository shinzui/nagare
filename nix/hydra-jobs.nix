{ pkgs, src }:

# This check predates the packaged CLI and still resolves private
# source-repository-package dependencies through Cabal. Keeping it outside
# `checks` makes `nix flake check` sandboxed and reproducible while the
# dedicated CI job continues to exercise nagare-access.
let
  ghc = pkgs.haskell.compiler.ghc912;
  haskellTooling = [ ghc pkgs.cabal-install pkgs.zlib pkgs.postgresql pkgs.pkg-config pkgs.git pkgs.cacert ];
in
{
nagare-access-build-test = pkgs.runCommand "nagare-access-build-test"
  { nativeBuildInputs = haskellTooling; src = src; __noChroot = true; }
  ''
    cp -r "$src" build && chmod -R +w build
    cd build/cli/nagare-access
    export HOME="$PWD/.home"
    export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    export LANG=C.UTF-8
    cabal update
    cabal build all
    cabal test nagare-access-test --test-show-details=streaming
    touch "$out"
  '';
}
