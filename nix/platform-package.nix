{ pkgs, sourceRoot, releaseVersion, sourceRevision ? null }:

let
  clusterSecretsRoot = toString (sourceRoot + /cluster/secrets);
  src = pkgs.lib.cleanSourceWith {
    src = sourceRoot;
    filter = path: type:
      let
        name = builtins.baseNameOf path;
        pathString = toString path;
        isClusterSecret = pathString == clusterSecretsRoot || pkgs.lib.hasPrefix "${clusterSecretsRoot}/" pathString;
      in
      !isClusterSecret
      && !(builtins.elem name [ ".direnv" ".git" ".pulumi-home" ".pulumi-state" "dist-newstyle" "node_modules" "result" ])
      && !(name != "Pulumi.yaml" && pkgs.lib.hasPrefix "Pulumi." name && pkgs.lib.hasSuffix ".yaml" name);
  };
in
pkgs.runCommand "nagare-platform-${releaseVersion}"
{
  inherit src;
  nativeBuildInputs = [ pkgs.jq ];
  revision = if sourceRevision == null then "" else sourceRevision;
} ''
  payload="$out/share/nagare"
  mkdir -p "$payload/infra" "$payload/docs/plans" "$payload/cli"

  payload_id="nagare-${releaseVersion}-source"
  if [ -n "$revision" ]; then
    payload_id="nagare-${releaseVersion}-''${revision:0:12}"
  fi
  jq \
    --arg version "${releaseVersion}" \
    --arg revision "$revision" \
    --arg payloadId "$payload_id" \
    '.platformVersion = $version
      | .sourceRevision = (if $revision == "" then null else $revision end)
      | .payloadId = $payloadId' \
    "$src/release.json" > "$payload/release.json"
  cp "$src/justfile" "$payload/justfile"
  cp -R "$src/cli/nagare-dsl" "$payload/cli/nagare-dsl"
  cp -R "$src/cli/nagare-access" "$payload/cli/nagare-access"
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
