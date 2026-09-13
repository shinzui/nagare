{ pkgs, nagarePackages, src }:

{
  nagare-platform-assets = pkgs.runCommand "nagare-platform-assets"
    { nativeBuildInputs = [ pkgs.jq ]; payload = nagarePackages.nagarePlatform; }
    ''
      bash ${./scripts/nagare-platform-assets.sh}
    '';

  nagare-clone-free-platform =
    let
      fakePulumi = pkgs.writeShellScriptBin "pulumi" ''
        printf '%s\n' "$*" >> "''${NAGARE_FAKE_TOOL_LOG:?}"
        case " $* " in
          *" config get gcp:project "*)
            # EP-113: the `nagarectl context guard` fixture drives the
            # stack's declared project from the environment, so the check
            # can exercise both the agreeing and the disagreeing verdict.
            printf '%s\n' "''${NAGARE_FAKE_STACK_PROJECT:-}"
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
