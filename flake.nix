{
  description = "nagare developer shell (project-pinned Pulumi + Haskell + cloud toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));
    in {
      # EP-5 (docs/plans/69, MasterPlan 13): CI as Nix flake checks — the SOURCE
      # OF TRUTH. `nix flake check` builds every entry below; the GitHub Actions
      # workflow (.github/workflows/ci.yml) is a thin shell that installs Nix and
      # runs the same command, so local and hosted behavior are identical.
      #
      # NETWORK: these derivations run `cabal`, which fetches Hackage deps and the
      # `cradle` source-repository-package from GitHub. Nix's build sandbox blocks
      # the network, so each is marked `__noChroot = true` and the checks are run
      # with a relaxed sandbox: locally `nix flake check` (macOS sandbox is off by
      # default); on CI the workflow sets `sandbox = relaxed`. The trade-off
      # (network-dependent, not fully hermetic) is the documented first iteration;
      # a later hardening can migrate to haskell.nix / callCabal2nix.
      #
      # NOTE: a `fourmolu-format` check is intentionally NOT included — the pinned
      # fourmolu (0.19.x) reformats 82/93 committed files (a version drift from the
      # older fourmolu that last formatted the tree, unrelated to any contributor's
      # change), so the check would be red on a clean tree. Re-pinning fourmolu or
      # a one-time tree-wide reformat is a separate follow-up; see this plan's
      # Surprises & Discoveries.
      checks = forAllSystems (pkgs:
        let
          ghc = pkgs.haskell.compiler.ghc912;
          # Tooling for the cabal-based checks: the pinned GHC + cabal, the C deps
          # (zlib via pkg-config, PostgreSQL/libpq for en-client's current dependency
          # closure), git (for source-repository-package dependencies), and CA certs
          # (for Hackage/GitHub https).
          haskellTooling = [ ghc pkgs.cabal-install pkgs.zlib pkgs.postgresql pkgs.pkg-config pkgs.git pkgs.cacert ];
          cabalEnv = ''
            export HOME="$PWD/.home"
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export LANG=C.UTF-8
          '';
        in {
          # Build + test nagare-dsl (the typed model + renderer).
          nagare-dsl-build-test = pkgs.runCommand "nagare-dsl-build-test"
            { nativeBuildInputs = haskellTooling; src = ./.; __noChroot = true; }
            ''
              cp -r "$src" build && chmod -R +w build
              cd build/cli/nagare-dsl
              ${cabalEnv}
              cabal update
              # `cabal build` (not the implicit build in `cabal test`) is what
              # materialises the .ghc.environment.* file (write-ghc-environment-files:
              # always). The loader tests (loadServerSite/loadSite) shell out to
              # runghc, which needs that file present to resolve nagare-dsl, so build
              # explicitly first.
              cabal build all
              cabal test nagare-dsl-test --test-show-details=streaming
              touch "$out"
            '';

          # Build + test nagarectl (builds against the local nagare-dsl per its cabal.project).
          nagarectl-build-test = pkgs.runCommand "nagarectl-build-test"
            { nativeBuildInputs = haskellTooling; src = ./.; __noChroot = true; }
            ''
              cp -r "$src" build && chmod -R +w build
              cd build/cli/nagarectl
              ${cabalEnv}
              cabal update
              cabal build all
              cabal test nagarectl-test --test-show-details=streaming
              touch "$out"
            '';

          # Build + test nagare-access (the shared forward-auth enforcer).
          nagare-access-build-test = pkgs.runCommand "nagare-access-build-test"
            { nativeBuildInputs = haskellTooling; src = ./.; __noChroot = true; }
            ''
              cp -r "$src" build && chmod -R +w build
              cd build/cli/nagare-access
              ${cabalEnv}
              cabal update
              cabal build all
              cabal test nagare-access-test --test-show-details=streaming
              touch "$out"
            '';

          # Compile-and-run every shipped cluster/examples/*/nagare/Config.hs through
          # the loader's runghc contract (runghc -XGHC2024 -i<dir>), resolving
          # nagare-dsl via `cabal exec` from the nagarectl package. This is the guard
          # that catches a rotted example (the 2026-06-10 audit found 3 silently broken).
          examples-compile = pkgs.runCommand "examples-compile"
            { nativeBuildInputs = haskellTooling; src = ./.; __noChroot = true; }
            ''
              cp -r "$src" build && chmod -R +w build
              cd build
              ${cabalEnv}
              ( cd cli/nagarectl && cabal update && cabal build all )
              fail=0
              for cfg in cluster/examples/*/nagare/Config.hs; do
                dir="$(dirname "$cfg")"
                echo "== compiling $cfg =="
                if ! ( cd cli/nagarectl && cabal exec -v0 -- \
                         runghc -XGHC2024 -i"../../$dir" "../../$cfg" >/dev/null ); then
                  echo "FAILED: $cfg" >&2
                  fail=1
                fi
              done
              [ "$fail" -eq 0 ] || exit 1
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
