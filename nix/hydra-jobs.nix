{ config, lib, withSystem, ... }:

{
  flake.hydraJobs = lib.genAttrs config.systems (system:
    withSystem system ({ pkgs, nagareSource, ... }:
      let
        ghc = pkgs.haskell.compiler.ghc9124;
        haskellTooling = [ ghc pkgs.cabal-install pkgs.zlib pkgs.postgresql pkgs.pkg-config pkgs.git pkgs.cacert ];
      in
      {
        nagare-access-build-test = pkgs.runCommand "nagare-access-build-test"
          { nativeBuildInputs = haskellTooling; src = nagareSource.src; __noChroot = true; }
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
      }));
}
