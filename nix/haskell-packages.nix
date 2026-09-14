{ pkgs, cradleSrc, platformPackage, sourceRevision ? null }:

let
  inherit (pkgs) lib;
  hl = pkgs.haskell.lib;

  haskellPackages = pkgs.haskell.packages.ghc9124.override {
    overrides = hfinal: _hprev: {
      generic-lens = hfinal.callHackage "generic-lens" "2.3.0.0" { };
      generic-lens-core = hfinal.callHackage "generic-lens-core" "2.3.0.0" { };

      cradle = hl.dontHaddock (hl.dontCheck (
        hfinal.callCabal2nix "cradle" cradleSrc { }
      ));

      nagare-dsl = hl.dontHaddock (hl.dontCheck (
        hfinal.callCabal2nix "nagare-dsl" ../cli/nagare-dsl { }
      ));

      nagarectl =
        let
          package = hfinal.callCabal2nix "nagarectl" ../cli/nagarectl { };
          revisionPackage =
            if sourceRevision == null then package
            else
              hl.overrideCabal package (_old: {
                postPatch = ''
                  substituteInPlace src/Nagare/Version.hs \
                    --replace-fail "revision = Nothing" \
                    'revision = Just "${sourceRevision}"'
                '';
              });
        in
        hl.dontHaddock (hl.dontCheck revisionPackage);
    };
  };

  typedConfigRuntime = haskellPackages.ghcWithPackages (hp: [ hp.nagare-dsl ]);
  operatorTools = [ pkgs.pulumi pkgs.pulumiPackages.pulumi-nodejs pkgs.socat ];

  checkedNagareDsl = hl.doCheck (
    hl.overrideCabal haskellPackages.nagare-dsl (_old: {
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

  checkedNagarectl = hl.doCheck (
    hl.overrideCabal haskellPackages.nagarectl (_old: {
      preCheck = ''
        export GHC_ENVIRONMENT=-
        export PATH=${lib.makeBinPath [ typedConfigRuntime ]}:$PATH
      '';
    })
  );

  nagarectl = pkgs.buildEnv {
    name = "nagarectl-${haskellPackages.nagarectl.version}";
    paths = [ haskellPackages.nagarectl ];
    pathsToLink = [ "/bin" "/share" "/nix-support" ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/nagarectl" \
        --prefix PATH : ${lib.makeBinPath [ typedConfigRuntime ]} \
        --set NAGARE_PLATFORM_ROOT ${platformPackage}/share/nagare
    '';
    meta.mainProgram = "nagarectl";
  };

  operatorNagarectl = pkgs.buildEnv {
    name = "nagare-operator-nagarectl-${haskellPackages.nagarectl.version}";
    paths = [ nagarectl ];
    pathsToLink = [ "/bin" "/share" "/nix-support" ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      # Deliberately append the tested Pulumi tools: an operator-provided binary
      # and the clone-free check's recording fake must remain able to win.
      wrapProgram "$out/bin/nagarectl" \
        --suffix PATH : ${lib.makeBinPath operatorTools}
    '';
    meta.mainProgram = "nagarectl";
  };

  nagareLauncher = pkgs.writeShellApplication {
    name = "nagare";
    runtimeInputs = [ operatorNagarectl pkgs.jq pkgs.just ];
    text = ''
      # Keep Pulumi behind the caller's PATH for the same reason as the
      # operatorNagarectl suffix above. Recipes invoke Pulumi directly.
      export PATH="$PATH:${lib.makeBinPath operatorTools}"
      export NAGARE_PLATFORM_ROOT="${platformPackage}/share/nagare"
      workspace_json="$(nagarectl platform root --json)"
      workspace_root="$(printf '%s' "$workspace_json" | jq -er '.workspaceRoot')"
      export NAGARE_WORKSPACE_ROOT="$workspace_root"
      # Listing recipes is read-only and must not require npm or initialize a
      # Pulumi context merely to inspect the installed operator interface.
      if [[ "''${1:-}" == "--list" ]]; then
        exec just --justfile "$workspace_root/justfile" --working-directory "$workspace_root" "$@"
      fi
      # EP-113: a clone-free install has no .envrc, so the launcher must export the
      # active context's CLOUDSDK_* / NAGARE_* / PULUMI_* contract itself. Without
      # this, `nagare infra-up` inherits whatever Pulumi state the invoking shell
      # happens to carry — which for a clone-free install is none. The evaluated
      # text is produced by `nagarectl context env`, which emits only shell-quoted
      # `export K=V` lines (see renderContextShellEnv in Nagare.Target).
      context_env="$(nagarectl context env)"
      eval "$context_env"
      exec just --justfile "$workspace_root/justfile" --working-directory "$workspace_root" "$@"
    '';
  };

  nagare = pkgs.buildEnv {
    name = "nagare-${haskellPackages.nagarectl.version}";
    paths = [ operatorNagarectl nagareLauncher ];
    pathsToLink = [ "/bin" "/share" "/nix-support" ];
    meta.mainProgram = "nagare";
  };
in
{
  inherit checkedNagareDsl checkedNagarectl haskellPackages nagare nagarectl operatorNagarectl typedConfigRuntime;
  nagarePlatform = platformPackage;
}
