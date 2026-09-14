{ pkgs, nagarePackages, src }:

let
  profileLinksFixture = pkgs.runCommand "nagare-profile-lib-links-fixture" { } ''
    mkdir -p "$out/lib/links"
    printf '%s\n' fixture > "$out/lib/links/libgmpxx.4.dylib"
  '';
in
{
  nagare-platform-assets = pkgs.runCommand "nagare-platform-assets"
    { nativeBuildInputs = [ pkgs.jq ]; payload = nagarePackages.nagarePlatform; }
    ''
      bash ${./scripts/nagare-platform-assets.sh}
    '';

  nagare-clone-free-platform =
    let
      fakePulumi = pkgs.writeShellScriptBin "pulumi" ''
        printf 'pulumi %s\n' "$*" >> "''${NAGARE_FAKE_TOOL_LOG:?}"
        case " $* " in
          *" config --json "*)
            # EP-129 / IR-9: a successful config listing can prove either that
            # gcp:project exists or that it is genuinely absent. Process
            # failure is a separate fixture and must retain stderr.
            case "''${NAGARE_FAKE_PULUMI_CONFIG_RESULT:-project}" in
              project)
                printf '{"gcp:project":{"value":"%s","secret":false}}\n' \
                  "''${NAGARE_FAKE_STACK_PROJECT:-}"
                ;;
              missing)
                printf '{}\n'
                ;;
              failed)
                printf '%s\n' 'error: could not access backend: test authentication failure' >&2
                exit 23
                ;;
            esac
            ;;
        esac
        exit 0
      '';
      # EP-121: workspaces install the Pulumi program's locked dependencies with
      # `npm ci`; the sandbox has no registry, so record the call and lay down
      # the marker the installer checks for.
      fakeNpm = pkgs.writeShellScriptBin "npm" ''
        printf '%s\n' "npm $* in $PWD" >> "''${NAGARE_FAKE_TOOL_LOG:?}"
        mkdir -p node_modules/@pulumi/pulumi
        printf '{}\n' > node_modules/@pulumi/pulumi/package.json
      '';
      fakeJsonTool = name: pkgs.writeShellScriptBin name ''
        printf '%s %s\n' "${name}" "$*" >> "''${NAGARE_FAKE_TOOL_LOG:?}"
        printf '%s\n' '{"items":[]}'
      '';
      fakeNix = pkgs.writeShellScriptBin "nix" ''
        printf '%s\n' "nix $*" >> "''${NAGARE_FAKE_TOOL_LOG:?}"
        printf '%s\n' "/nix/store/fake-nagare-upgrade-result"
      '';
      fakeTools = pkgs.symlinkJoin {
        name = "nagare-fake-platform-tools";
        paths = map fakeJsonTool [ "curl" "gcloud" "gsutil" "kubectl" ];
      };
    in
    pkgs.runCommand "nagare-clone-free-platform"
      { nativeBuildInputs = [ nagarePackages.nagare pkgs.jq fakeNix fakeNpm fakePulumi fakeTools ]; }
      ''
        bash ${./scripts/nagare-clone-free-platform.sh}
      '';

  nagare-operator-tools = pkgs.runCommand "nagare-operator-tools" { } ''
    ${pkgs.bash}/bin/bash ${./scripts/nagare-operator-tools.sh} \
      ${nagarePackages.nagare} \
      ${nagarePackages.nagarectl} \
      ${nagarePackages.haskellPackages.nagarectl}/bin/nagarectl \
      ${nagarePackages.nagarePlatform}/share/nagare \
      ${pkgs.jq}/bin/jq \
      ${pkgs.coreutils} \
      ${pkgs.bash} \
      ${pkgs.gnugrep}/bin/grep
  '';

  release-consistency-source = pkgs.runCommand "release-consistency-source"
    { nativeBuildInputs = [ pkgs.bash pkgs.git pkgs.jq ]; src = src; }
    ''
      cp -R "$src" source
      chmod -R u+w source
      cd source
      bash ./scripts/test-release.sh
      touch "$out"
    '';
}
  // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
  nagare-darwin-profile-install = pkgs.buildEnv {
    name = "nagare-darwin-profile-install";
    paths = [ profileLinksFixture nagarePackages.nagare ];
    ignoreCollisions = false;
  };
}
