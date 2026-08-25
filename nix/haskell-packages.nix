{ pkgs, cradleSrc }:

let
  inherit (pkgs) lib;

  haskellPackages = pkgs.haskell.packages.ghc912.override {
    overrides = hfinal: _hprev: {
      cradle = pkgs.haskell.lib.dontCheck (
        hfinal.callCabal2nix "cradle" cradleSrc { }
      );

      nagare-dsl = pkgs.haskell.lib.dontCheck (
        hfinal.callCabal2nix "nagare-dsl" ../cli/nagare-dsl { }
      );

      nagarectl = pkgs.haskell.lib.dontCheck (
        hfinal.callCabal2nix "nagarectl" ../cli/nagarectl { }
      );
    };
  };

  typedConfigRuntime = haskellPackages.ghcWithPackages (hp: [ hp.nagare-dsl ]);

  checkedNagareDsl = pkgs.haskell.lib.doCheck (
    pkgs.haskell.lib.overrideCabal haskellPackages.nagare-dsl (_old: {
      postPatch = ''
        substituteInPlace test/ApplicationSpec.hs test/WorkerSpec.hs test/Spec.hs \
          --replace-fail "../../cluster/examples" "${../cluster/examples}"
      '';
      preCheck = ''
        export GHC_ENVIRONMENT=-
        export PATH=${lib.makeBinPath [ typedConfigRuntime ]}:$PATH
      '';
    })
  );

  checkedNagarectl = pkgs.haskell.lib.doCheck (
    pkgs.haskell.lib.overrideCabal haskellPackages.nagarectl (_old: {
      preCheck = ''
        export GHC_ENVIRONMENT=-
        export PATH=${lib.makeBinPath [ typedConfigRuntime ]}:$PATH
      '';
    })
  );

  nagarectl = pkgs.symlinkJoin {
    name = "nagarectl-${haskellPackages.nagarectl.version}";
    paths = [ haskellPackages.nagarectl ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/nagarectl" \
        --prefix PATH : ${lib.makeBinPath [ typedConfigRuntime ]}
    '';
    meta.mainProgram = "nagarectl";
  };
in
{
  inherit checkedNagareDsl checkedNagarectl haskellPackages nagarectl typedConfigRuntime;
}
