{
  description = "nagare developer shell (project-pinned Pulumi + Haskell + cloud toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.cradle = {
    url = "github:garnix-io/cradle/711c441fa8f190a8964c56a3bae864cd5321c5c5";
    flake = false;
  };

  outputs = { self, nixpkgs, cradle }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));
      nagarePackagesFor = pkgs:
        import ./nix/haskell-packages.nix { inherit pkgs; cradleSrc = cradle; };
    in
    {
      packages = forAllSystems (pkgs:
        let nagarePackages = nagarePackagesFor pkgs;
        in {
          inherit (nagarePackages) nagarectl;
          default = nagarePackages.nagarectl;
        });

      apps = forAllSystems (pkgs:
        let
          app = {
            type = "app";
            program = "${(nagarePackagesFor pkgs).nagarectl}/bin/nagarectl";
          };
        in
        {
          nagarectl = app;
          default = app;
        });

      # EP-5 (docs/plans/69, MasterPlan 13): `nix flake check` is the hermetic
      # source of truth for Nagare's packages, examples, and scripts. The one
      # inherited networked Cabal check for nagare-access is kept separately in
      # `hydraJobs` until that executable gets its own package derivation.
      #
      # NOTE: a `fourmolu-format` check is intentionally NOT included — the pinned
      # fourmolu (0.19.x) reformats 82/93 committed files (a version drift from the
      # older fourmolu that last formatted the tree, unrelated to any contributor's
      # change), so the check would be red on a clean tree. Re-pinning fourmolu or
      # a one-time tree-wide reformat is a separate follow-up; see this plan's
      # Surprises & Discoveries.
      checks = forAllSystems (pkgs:
        let
          nagarePackages = nagarePackagesFor pkgs;
        in
        {
          # Build and test the typed DSL and CLI through the hermetic package set.
          nagare-dsl-build-test = nagarePackages.checkedNagareDsl;
          nagarectl-build-test = nagarePackages.checkedNagarectl;

          # Compile-and-run every shipped cluster/examples/*/nagare/Config.hs through
          # the same packaged runghc runtime used by the installed CLI.
          examples-compile = pkgs.runCommand "examples-compile"
            { nativeBuildInputs = [ nagarePackages.typedConfigRuntime ]; src = ./.; }
            ''
              cd "$src"
              fail=0
              for cfg in cluster/examples/*/nagare/Config.hs; do
                dir="$(dirname "$cfg")"
                echo "== compiling $cfg =="
                if ! runghc -XGHC2024 -i"$dir" "$cfg" >/dev/null; then
                  echo "FAILED: $cfg" >&2
                  fail=1
                fi
              done
              [ "$fail" -eq 0 ] || exit 1
              touch "$out"
            '';

          # Prove the installed wrapper loads a typed config from a directory with
          # no Nagare checkout ancestor and no Cabal-generated package environment.
          nagarectl-external-config = pkgs.runCommand "nagarectl-external-config"
            { nativeBuildInputs = [ nagarePackages.nagarectl ]; src = ./.; }
            ''
              mkdir -p isolated/nagare
              cp "$src/cluster/examples/hello-knative-service/nagare/Config.hs" isolated/nagare/Config.hs
              cd isolated
              unset GHC_ENVIRONMENT NAGARE_GHC_ENVIRONMENT
              nagarectl deploy --dry-run --file "$PWD/nagare/Config.hs" > output
              grep -q "kind: Service" output
              grep -q "name: hello" output

              cat > nagare/Invalid.hs <<'INVALID_CONFIG'
              module Main where

              import Nagare.Dsl.Config (emitDeployment)

              main :: IO ()
              main = emitDeployment missingDeployment
              INVALID_CONFIG
              if nagarectl deploy --dry-run --file "$PWD/nagare/Invalid.hs" \
                > invalid-output 2> invalid-error; then
                echo "invalid typed config unexpectedly succeeded" >&2
                exit 1
              fi
              grep -q "nagare: compile error" invalid-error
              if grep -Eqi 'docker|kubectl|knative' invalid-output invalid-error; then
                echo "invalid typed config reached an external deployment phase" >&2
                exit 1
              fi
              touch "$out"
            '';

          # Lint the shell scripts at error severity (clean on the current tree;
          # SC1091 "not following sourced file" and SC2034 "appears unused" — the
          # TARGET_* vars other scripts consume — are info/warning, not errors).
          shellcheck-scripts = pkgs.runCommand "shellcheck-scripts"
            { nativeBuildInputs = [ pkgs.shellcheck ]; src = ./.; }
            ''
              cd "$src"
              shellcheck --severity=error scripts/*.sh scripts/lib/*.sh
              touch "$out"
            '';
        });

      # This check predates the packaged CLI and still resolves private
      # source-repository-package dependencies through Cabal. Keeping it outside
      # `checks` makes `nix flake check` sandboxed and reproducible while the
      # dedicated CI job continues to exercise nagare-access.
      hydraJobs = forAllSystems (pkgs:
        let
          ghc = pkgs.haskell.compiler.ghc912;
          haskellTooling = [ ghc pkgs.cabal-install pkgs.zlib pkgs.postgresql pkgs.pkg-config pkgs.git pkgs.cacert ];
        in
        {
          nagare-access-build-test = pkgs.runCommand "nagare-access-build-test"
            { nativeBuildInputs = haskellTooling; src = ./.; __noChroot = true; }
            ''
              cp -r "$src" build && chmod -R +w build
              cd build/cli/nagare-access
              export HOME="$PWD/.home"
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              export LANG=C.UTF-8
              cabal update
              cabal build all
              cabal test nagare-access-test --test-show-details=streaming
              touch "$out"
            '';
        });

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
        in
        {
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
              # k3d runs k3s inside Docker for local-mode development — EP-82
              # (MasterPlan 16). `just local-up` uses it to stand up the local
              # cluster + registry; needs a running Docker daemon.
              pkgs.k3d
              # Secret encryption — EP-3/EP-7.
              pkgs.sops
              pkgs.age
              # Private network access to the host — EP-3.
              pkgs.tailscale
              # JSON wrangling in scripts — used across plans.
              pkgs.jq
              # The command runner that reads ./justfile.
              pkgs.just
              # Haskell toolchain pinned to GHC 9.12 (house standard;
              # see haskell-jitsurei/core/standards.md). Pattern mirrors
              # bokuno/nix/nix-flake-templates/haskell-9_12/flake.nix.
              # Originally EP-6's unpinned pkgs.ghc (~9.10); re-pinned to
              # 9.12 by EP-8 M0 (MasterPlan 2, Integration Point 6) so the
              # nagare-dsl initiative inherits the house toolchain. GHC's
              # closure is large (multiple GB); see the optional split below.
              pkgs.haskell.compiler.ghc912
              pkgs.cabal-install
              pkgs.haskell.packages.ghc912.haskell-language-server
              pkgs.haskell.packages.ghc912.fourmolu
              pkgs.haskell.packages.ghc912.cabal-gild
              pkgs.zlib
              pkgs.postgresql
              pkgs.pkg-config
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
            packages = [
              pkgs.haskell.compiler.ghc912
              pkgs.cabal-install
              pkgs.zlib
              pkgs.postgresql
              pkgs.pkg-config
              # k3d for local-mode development parity with the default shell — EP-82.
              pkgs.k3d
            ];
          };
        });
    };
}
