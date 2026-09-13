{ pkgs }:

let
# Pulumi 3.239.0 is upstream's current release at the time this
# repo was scaffolded; nixpkgs ships an older one. We override
# version + source + vendor hashes so the dev shell ships a
# current CLI without waiting for nixpkgs to bump. The shape of
# this override is copied verbatim from the sibling reference
# repo /Users/shinzui/Keikaku/bokuno/load-testing-infra/flake.nix.
#
# IMPORTANT: the two `vendorHash` values below are SPECIFIC TO
# THIS RELEASE. If you bump `version`, they will be wrong and the
# build will fail with a hash mismatch. See the plan section
# "Refreshing the Pulumi hashes" for how to obtain new ones.
pulumi = pkgs.pulumi.overrideAttrs (_: rec {
  version = "3.239.0";
  src = pkgs.fetchFromGitHub {
    owner = "pulumi";
    repo = "pulumi";
    tag = "v${version}";
    hash = "sha256-dkBiEKK0qgQOATolv4o49yIUk0W6uf27LWaESoLhOU4=";
    name = "pulumi";
  };
  vendorHash = "sha256-xdTsh3tbosIisvYZPYyIVHi7p/9ex7+MO/8v2OYe32c=";
  # Two log-decryption tests fail in 3.239.0's sandbox build
  # (TestDecryptEncryptedLog, TestDecryptGzipLog). Upstream CI
  # validates the release; we consume the binary and skip tests.
  doCheck = false;
});
pulumi-nodejs =
  ((pkgs.pulumiPackages.pulumi-nodejs.override { inherit pulumi; }).overrideAttrs (_: {
    vendorHash = "sha256-1Jxo09ecpeOR7X5Tdn3hI0OZUfqPKuLVxnXA4ElGspY=";
    # The 3.239.0 language tests invoke external version managers
    # (fnm, bun) not present in the build sandbox; we only need
    # the resource binary, so skip the tests.
    doCheck = false;
    # `pulumi-analyzer-policy` was removed from sdk/nodejs/dist/
    # between the nixpkgs-pinned version and 3.239.0; only the
    # resource binary remains. The upstream postInstall hard-codes
    # both, so we redefine it to copy just the one that exists.
    postInstall = ''
      cp -t "$out/bin" ../../dist/pulumi-resource-pulumi-nodejs
    '';
  }));
in
{
  inherit pulumi pulumi-nodejs;
}
