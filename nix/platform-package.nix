{ pkgs, sourceRoot }:

let
  src = pkgs.lib.cleanSourceWith {
    src = sourceRoot;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in !(builtins.elem name [ ".direnv" ".git" ".pulumi-home" ".pulumi-state" "dist-newstyle" "node_modules" "result" ])
        && !(name != "Pulumi.yaml" && pkgs.lib.hasPrefix "Pulumi." name && pkgs.lib.hasSuffix ".yaml" name);
  };
in
pkgs.runCommand "nagare-platform-0.1.0" { inherit src; } ''
  payload="$out/share/nagare"
  mkdir -p "$payload/infra" "$payload/docs/plans"

  cp "$src/release.json" "$payload/release.json"
  cp "$src/justfile" "$payload/justfile"
  cp -R "$src/infra/pulumi" "$payload/infra/pulumi"
  cp -R "$src/cluster" "$payload/cluster"
  cp -R "$src/scripts" "$payload/scripts"
  cp -R "$src/nixos" "$payload/nixos"
  cp -R "$src/docs/user" "$payload/docs/user"
  cp -R "$src/docs/runbooks" "$payload/docs/runbooks"
  cp "$src/docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md" "$payload/docs/plans/"
  cp "$src/docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md" "$payload/docs/plans/"

  chmod -R u+rwX,go+rX "$payload"
''
