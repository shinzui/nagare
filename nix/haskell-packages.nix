{ pkgs, cradleSrc, platformPackage, sourceRevision ? null }:

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

      nagarectl =
        let
          package = hfinal.callCabal2nix "nagarectl" ../cli/nagarectl { };
          revisionPackage =
            if sourceRevision == null then package
            else pkgs.haskell.lib.overrideCabal package (_old: {
              postPatch = ''
                substituteInPlace src/Nagare/Version.hs \
                  --replace-fail "revisionText = Nothing" \
                  'revisionText = Just "${sourceRevision}"'
              '';
            });
        in
        pkgs.haskell.lib.dontCheck revisionPackage;
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
        --prefix PATH : ${lib.makeBinPath [ typedConfigRuntime ]} \
        --set NAGARE_PLATFORM_ROOT ${platformPackage}/share/nagare
    '';
    meta.mainProgram = "nagarectl";
  };

  nagareLauncher = pkgs.writeShellApplication {
    name = "nagare";
    runtimeInputs = [ nagarectl pkgs.jq pkgs.just ];
    text = ''
      export NAGARE_PLATFORM_ROOT="${platformPackage}/share/nagare"
      workspace_json="$(nagarectl platform root --json)"
      workspace_root="$(printf '%s' "$workspace_json" | jq -er '.workspaceRoot')"
      export NAGARE_WORKSPACE_ROOT="$workspace_root"
      exec just --justfile "$workspace_root/justfile" --working-directory "$workspace_root" "$@"
    '';
  };

  nagare = pkgs.symlinkJoin {
    name = "nagare-${haskellPackages.nagarectl.version}";
    paths = [ nagarectl nagareLauncher ];
    meta.mainProgram = "nagare";
  };
in
{
  inherit checkedNagareDsl checkedNagarectl haskellPackages nagare nagarectl typedConfigRuntime;
  nagarePlatform = platformPackage;
}
