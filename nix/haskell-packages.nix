{ pkgs, cradleSrc, gogolSrc, platformPackage, atticClient, sourceRevision ? null }:

let
  inherit (pkgs) lib;
  hl = pkgs.haskell.lib;

  # Compile the git revision into nagarectl? OFF until MasterPlans 24, 25 and
  # 26 are finished (operator decision, 2026-10-05; EP-178). Stamping makes every
  # commit, docs-only commits included, rebuild and retest nagarectl on every
  # system. While it is off, the shipped wrapper below sets
  # NAGARE_SOURCE_REVISION, and `nagarectl version --json` reports it, so the
  # release tooling (check-release.sh, assemble-release.sh,
  # rehearse-clone-free-release.sh) keeps working.
  stampRevision = false;

  # Nagare's own packages: no library profiling (nothing uses it, and it is a
  # second full compile pass), no Haddock. Tests run in the one derivation that
  # ships, so each package compiles once per system.
  nagarePackage = drv: hl.dontHaddock (hl.disableLibraryProfiling drv);

  # The nagarectl tests read payload files from cluster/ and run payload scripts
  # (for example the Helm capture plugin). A Linux build sandbox has no
  # /usr/bin/env, so they read a copy of cluster/ alone, with store-path
  # interpreters. It is cluster/ only, so other repository changes do not
  # invalidate the tested build.
  sourceForTests = pkgs.runCommand "nagare-source-for-tests" { } ''
    mkdir -p "$out"
    cp -R ${../cluster} "$out/cluster"
    chmod -R u+w "$out"
    patchShebangs "$out/cluster"
  '';

  haskellPackages = pkgs.haskell.packages.ghc9124.override {
    overrides = hfinal: _hprev: {
      generic-lens = hfinal.callHackage "generic-lens" "2.3.0.0" { };
      generic-lens-core = hfinal.callHackage "generic-lens-core" "2.3.0.0" { };

      # Match the released interpreter dependency used by the Cabal pilot.
      # mori://effectful/effectful/packages/effectful-core
      effectful-core = hfinal.callCabal2nix "effectful-core" (builtins.fetchTarball {
        url = "https://hackage.haskell.org/package/effectful-core-2.7.1.2/effectful-core-2.7.1.2.tar.gz";
        sha256 = "1kswfv5cz9rz1fs2j10w7fgy2pdwq84h257a2wb17p0q8n9ld61r";
      }) { };
      strict-mutable-base = hfinal.callCabal2nix "strict-mutable-base" (builtins.fetchTarball {
        url = "https://hackage.haskell.org/package/strict-mutable-base-2.0.0.0/strict-mutable-base-2.0.0.0.tar.gz";
        sha256 = "1sdps117s8vdirhwqfma1b37q1i5dg939cmsa3xsbrr5vwq8z3fy";
      }) { };

      cradle = hl.dontHaddock (hl.dontCheck (
        hfinal.callCabal2nix "cradle" cradleSrc { }
      ));

      # Only the same stale upper bounds relaxed in Cabal; no source changes.
      gogol-core = hl.dontHaddock (hl.dontCheck (hl.overrideCabal
        (hfinal.callCabal2nix "gogol-core" (gogolSrc + "/lib/gogol-core") { })
        (_old: {
          postPatch = ''
            substituteInPlace gogol-core.cabal \
              --replace-fail 'aeson                 >=0.8    && <2.3' 'aeson >=0.8'
          '';
        })));
      gogol = hl.dontHaddock (hl.dontCheck (hl.overrideCabal
        (hfinal.callCabal2nix "gogol" (gogolSrc + "/lib/gogol") { })
        (_old: {
          postPatch = ''
            substituteInPlace gogol.cabal \
              --replace-fail 'aeson               >=0.8   && <2.3' 'aeson >=0.8' \
              --replace-fail 'crypton             >=0.34  && <1.1' 'crypton >=0.34' \
              --replace-fail 'crypton-x509        >=1.5   && <1.8' 'crypton-x509 >=1.5' \
              --replace-fail 'crypton-x509-store  >=1.5   && <1.7' 'crypton-x509-store >=1.5'
          '';
        })));
      gogol-storage = hl.dontHaddock (hl.dontCheck (
        hfinal.callCabal2nix "gogol-storage" (gogolSrc + "/lib/services/gogol-storage") { }
      ));

      # nagare-dsl's loader tests need a GHC that already has nagare-dsl
      # (typedConfigRuntime), so its tests run in a separate derivation below;
      # it is small (61 modules). nagarectl, the expensive one, tests in place.
      nagare-dsl = nagarePackage (hl.dontCheck (
        hfinal.callCabal2nix "nagare-dsl" ../cli/nagare-dsl { }
      ));

      # EP-174: the local gate and acceptance harness (maintainer tooling,
      # outside the platform payload).
      nagare-harness = nagarePackage (hl.overrideCabal (hfinal.callCabal2nix "nagare-harness" ../cli/nagare-harness { }) (_old: {
        postPatch = ''
          substituteInPlace test/Spec.hs \
            --replace-fail "../../fixtures/inventory-release/local" "${../fixtures/inventory-release/local}"
        '';
      }));

      nagarectl =
        let
          package = hfinal.callCabal2nix "nagarectl" ../cli/nagarectl { };
          revisionPackage =
            if !stampRevision || sourceRevision == null then package
            else
              hl.overrideCabal package (_old: {
                postPatch = ''
                  substituteInPlace src/Nagare/Version.hs \
                    --replace-fail "compiledRevision = Nothing" \
                    'compiledRevision = Just "${sourceRevision}"'
                '';
              });
        in
        nagarePackage (hl.doCheck (
          hl.overrideCabal revisionPackage (_old: {
            postPatch = (_old.postPatch or "") + ''
              substituteInPlace \
                test/InventoryUpstreamSpec.hs test/InventoryApplicationSpec.hs \
                test/InventoryFoundationSpec.hs test/InventoryAuthSpec.hs \
                test/InventoryObservabilitySpec.hs test/InventoryCacheSpec.hs \
                --replace-fail "../../cluster/" "${sourceForTests}/cluster/"
              substituteInPlace test/AppDeploySpec.hs test/InventoryApplicationSpec.hs \
                --replace-fail "../nagare-dsl/test/fixtures/" "${../cli/nagare-dsl/test/fixtures}/"
              substituteInPlace \
                test/InventoryUpstreamSpec.hs test/InventoryObservabilitySpec.hs \
                test/InventoryCacheSpec.hs test/InventoryAuthSpec.hs \
                --replace-fail '"../.."' '"${sourceForTests}"'
            '';
            preCheck = ''
              export GHC_ENVIRONMENT=-
              export PATH=${lib.makeBinPath [ typedConfigRuntime pkgs.kubernetes-helm pkgs.openssl pkgs.jq pkgs.python3 pkgs.perl ]}:$PATH
              export HELM_CACHE_HOME="$TMPDIR/nagare-helm-cache"
              mkdir -p "$HELM_CACHE_HOME"
            '';
          })
        ));
    };
  };

  typedConfigRuntime = haskellPackages.ghcWithPackages (hp: [ hp.nagare-dsl ]);
  nixBuilderProxy = pkgs.writeShellApplication {
    name = "nagare-nix-builder-proxy";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.socat ];
    text = builtins.readFile ../scripts/nix-builder-proxy.sh;
  };
  operatorTools = [
    atticClient
    pkgs.pulumi
    pkgs.pulumiPackages.pulumi-nodejs
    # The Pulumi program is TypeScript: its language host runs node, and a
    # payload workspace installs its locked dependencies with npm ci.
    pkgs.nodejs
    pkgs.socat
    pkgs.skopeo
    nixBuilderProxy
  ];

  # nagarectl and nagare-harness run their own tests in the derivation that
  # ships (one compile per system); the flake checks keep their attribute names.
  checkedNagareDsl = hl.doCheck (
    hl.overrideCabal haskellPackages.nagare-dsl (_old: {
      postPatch = ''
        substituteInPlace test/ApplicationSpec.hs test/WorkerSpec.hs test/Spec.hs \
          --replace-fail "../../cluster/examples" "${../cluster/examples}"
        substituteInPlace test/ResourceInventorySpec.hs \
          --replace-fail "../../cluster/bootstrap/nix-cache" "${../cluster/bootstrap/nix-cache}"
      '';
      preCheck = ''
        export GHC_ENVIRONMENT=-
        export PATH=${lib.makeBinPath [ typedConfigRuntime ]}:$PATH
      '';
    })
  );
  checkedNagarectl = haskellPackages.nagarectl;

  nagarectl = pkgs.buildEnv {
    name = "nagarectl-${haskellPackages.nagarectl.version}";
    paths = [ haskellPackages.nagarectl ];
    pathsToLink = [ "/bin" "/share" "/nix-support" ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/nagarectl" \
        --prefix PATH : ${lib.makeBinPath [ typedConfigRuntime pkgs.bind.dnsutils ]} \
        --set-default NAGARE_PLATFORM_ROOT ${platformPackage}/share/nagare \
        ${lib.optionalString (sourceRevision != null) "--set NAGARE_SOURCE_REVISION ${sourceRevision}"}
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
      export NAGARE_PLATFORM_ROOT="''${NAGARE_PLATFORM_ROOT:-${platformPackage}/share/nagare}"
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
    # Attic and skopeo are also direct release outputs: clone-free operators
    # can invoke them from #nagare, while the wrapper PATH continues to expose
    # the complete operator tool set to recipes and nagarectl subprocesses.
    paths = [ operatorNagarectl nagareLauncher nixBuilderProxy atticClient pkgs.skopeo ];
    pathsToLink = [ "/bin" "/share" "/nix-support" ];
    meta.mainProgram = "nagare";
  };
in
{
  checkedNagareHarness = haskellPackages.nagare-harness;
  inherit atticClient checkedNagareDsl checkedNagarectl haskellPackages nagare nagarectl nixBuilderProxy operatorNagarectl typedConfigRuntime;
  nagarePlatform = platformPackage;
}
