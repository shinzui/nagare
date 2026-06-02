{
  description = "nagare developer shell (project-pinned Pulumi + Haskell + cloud toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));
    in {
      devShells = forAllSystems (pkgs:
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
        in {
          default = pkgs.mkShell {
            name = "nagare";
            packages = [
              # Pulumi (provisioning) — Integration Point 8 / EP-2.
              pulumi
              pulumi-nodejs
              # nodejs_22 is the current active LTS. The plan originally
              # pinned nodejs_20, but the nixos-unstable channel now marks
              # that release insecure (EOL), which refuses to evaluate; see
              # the Decision Log and Surprises & Discoveries in EP-1.
              pkgs.nodejs_22
              pkgs.typescript
              # Google Cloud SDK provides both `gcloud` and `gsutil` — EP-2/3/4/7.
              pkgs.google-cloud-sdk
              # socat: ssh ProxyCommand for IAP tunnels, working around the
              # macOS OpenSSH 10.x <-> gcloud --tunnel-through-iap bug noted
              # in the reference repo. — EP-2/EP-3.
              pkgs.socat
              # Kubernetes + Helm clients — EP-4/EP-5/EP-6.
              pkgs.kubectl
              pkgs.kubernetes-helm
              # Secret encryption — EP-3/EP-7.
              pkgs.sops
              pkgs.age
              # Private network access to the host — EP-3.
              pkgs.tailscale
              # JSON wrangling in scripts — used across plans.
              pkgs.jq
              # The command runner that reads ./justfile.
              pkgs.just
              # Haskell toolchain for nagarectl — EP-6. GHC's closure is
              # large (multiple GB); see the plan for an optional split.
              pkgs.ghc
              pkgs.cabal-install
            ];
            shellHook = ''
              export PULUMI_HOME="''${PWD}/infra/pulumi/.pulumi-home"
            '';
          };

          # OPTIONAL lighter shell without the Haskell compiler, for readers
          # who do not need to build nagarectl and want a smaller download.
          # Enter it with `nix develop .#haskell`-style targets reversed:
          # this one is `nix develop` minus GHC. Kept here as documentation
          # of the split option from the Decision Log; safe to delete if
          # unused.
          haskell = pkgs.mkShell {
            name = "nagare-haskell";
            packages = [ pkgs.ghc pkgs.cabal-install ];
          };
        });
    };
}
