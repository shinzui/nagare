{
  description = "nagare developer shell (project-pinned Pulumi + Haskell + cloud toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.cradle = {
    url = "github:garnix-io/cradle/711c441fa8f190a8964c56a3bae864cd5321c5c5";
    flake = false;
  };

  outputs = { self, nixpkgs, cradle }:
    let
      releaseMetadata = builtins.fromJSON (builtins.readFile ./release.json);
      releaseVersion = releaseMetadata.platformVersion;
      systems = releaseMetadata.supportedSystems;
      sourceRevision =
        if self ? rev then self.rev
        else if self ? dirtyRev then self.dirtyRev
        else null;
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));
      nagarePackagesFor = pkgs:
        let
          platformPackage = import ./nix/platform-package.nix {
            inherit pkgs releaseVersion sourceRevision;
            sourceRoot = ./.;
          };
        in
        import ./nix/haskell-packages.nix {
          inherit pkgs platformPackage sourceRevision;
          cradleSrc = cradle;
        };
    in
    {
      lib.release = {
        version = releaseVersion;
        inherit sourceRevision;
        supportedSystems = systems;
      };

      packages = forAllSystems (pkgs:
        let nagarePackages = nagarePackagesFor pkgs;
        in {
          inherit (nagarePackages) nagarectl;
          nagare-platform = nagarePackages.nagarePlatform;
          nagare = nagarePackages.nagare;
          release-tools = pkgs.symlinkJoin {
            name = "nagare-release-tools";
            paths = [ pkgs.coreutils pkgs.jq ];
          };
          default = nagarePackages.nagarectl;
        });

      apps = forAllSystems (pkgs:
        let
          nagarePackages = nagarePackagesFor pkgs;
          app = {
            type = "app";
            program = "${nagarePackages.nagarectl}/bin/nagarectl";
          };
        in
        {
          nagarectl = app;
          nagare = {
            type = "app";
            program = "${nagarePackages.nagare}/bin/nagare";
          };
          default = app;
        });

      # EP-5 (docs/plans/69, MasterPlan 13): `nix flake check` is the hermetic
      # source of truth for Nagare's packages, examples, and scripts. The one
      # inherited networked Cabal check for nagare-access is kept separately in
      # `hydraJobs` until that executable gets its own package derivation.
      #
      # EP-119 formats all maintained Haskell with the pinned Fourmolu and checks
      # structural house-style rules with ast-grep, so formatting drift is now a
      # hermetic flake failure rather than an out-of-band convention.
      checks = forAllSystems (pkgs:
        let
          nagarePackages = nagarePackagesFor pkgs;
        in
        {
          # Build and test the typed DSL and CLI through the hermetic package set.
          nagare-dsl-build-test = nagarePackages.checkedNagareDsl;
          nagarectl-build-test = nagarePackages.checkedNagarectl;

          haskell-style = pkgs.runCommand "haskell-style"
            {
              nativeBuildInputs = [
                pkgs.ast-grep
                pkgs.bash
                pkgs.coreutils
                pkgs.findutils
                pkgs.ripgrep
                pkgs.haskell.packages.ghc912.fourmolu
                pkgs.haskell.packages.ghc912.cabal-gild
              ];
              src = ./.;
            }
            ''
              cd "$src"
              scripts/check-haskell-style.sh
              find cli -type f -name '*.hs' -print0 \
                | sort -z \
                | xargs -0 fourmolu --mode check --config cli/fourmolu.yaml \
                    --ghc-opt=-XImportQualifiedPost
              cabal-gild --mode check --input cli/nagare-dsl/nagare-dsl.cabal
              cabal-gild --mode check --input cli/nagarectl/nagarectl.cabal
              cabal-gild --mode check --input cli/nagare-access/nagare-access.cabal
              touch "$out"
            '';

          nagare-platform-assets = pkgs.runCommand "nagare-platform-assets"
            { nativeBuildInputs = [ pkgs.jq ]; payload = nagarePackages.nagarePlatform; }
            ''
              root="$payload/share/nagare"
              jq -e '.assetSchemaVersion == 1 and (.payloadId | length > 0)' "$root/release.json" >/dev/null
              test -f "$root/infra/pulumi/Pulumi.yaml"
              test -f "$root/cli/nagare-dsl/nagare-dsl.cabal"
              test -f "$root/cli/nagare-access/nagare-access.cabal"
              test -f "$root/cli/nagare-access/Dockerfile"
              test -f "$root/cluster/bootstrap/render-context-template.sh"
              test -f "$root/cluster/examples/uploads-volume/nagare/Config.hs"
              test ! -e "$root/cluster/secrets"
              test -f "$root/nixos/flake.nix"
              test -f "$root/scripts/lib/target.sh"
              test -f "$root/scripts/lib/release.sh"
              test -f "$root/scripts/lib/cluster-secrets.sh"
              test -f "$root/justfile"
              test -f "$root/docs/user/reference.md"
              touch "$out"
            '';

          infra-vm-shape = pkgs.runCommand "nagare-infra-vm-shape-test"
            { nativeBuildInputs = [ pkgs.nodejs pkgs.typescript ]; src = ./.; }
            ''
              mkdir build
              tsc --strict --target ES2020 --module commonjs --outDir build \
                "$src/infra/pulumi/src/vmShape.ts" \
                "$src/infra/pulumi/test/vmShape.test.ts"
              node build/test/vmShape.test.js | grep -qx ok
              touch "$out"
            '';

          vm-shape-defaults-agree = pkgs.runCommand "nagare-vm-shape-defaults-agree"
            { nativeBuildInputs = [ pkgs.coreutils pkgs.gnused ]; src = ./.; }
            ''
              ts="$src/infra/pulumi/src/vmShape.ts"
              hs="$src/cli/nagarectl/src/Nagare/Target.hs"
              compare_default() {
                label="$1"
                ts_pattern="$2"
                hs_pattern="$3"
                ts_value="$(sed -n "$ts_pattern" "$ts" | head -n 1)"
                hs_value="$(sed -n "$hs_pattern" "$hs" | head -n 1)"
                test -n "$ts_value"
                test "$ts_value" = "$hs_value" || {
                  echo "$label default differs: TypeScript=$ts_value Haskell=$hs_value" >&2
                  exit 1
                }
              }
              compare_default machineType 's/^[[:space:]]*machineType: "\([^"]*\)",/\1/p' 's/.*vsMachineType = "\([^"]*\)".*/\1/p'
              compare_default bootDiskType 's/^[[:space:]]*bootDiskType: "\([^"]*\)",/\1/p' 's/.*vsBootDiskType = "\([^"]*\)".*/\1/p'
              compare_default bootDiskSizeGb 's/^[[:space:]]*bootDiskSizeGb: \([0-9][0-9]*\),/\1/p' 's/.*vsBootDiskSizeGb = "\([0-9][0-9]*\)".*/\1/p'
              compare_default dataDiskSizeGb 's/^[[:space:]]*dataDiskSizeGb: \([0-9][0-9]*\),/\1/p' 's/.*vsDataDiskSizeGb = "\([0-9][0-9]*\)".*/\1/p'
              touch "$out"
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
              { nativeBuildInputs = [ nagarePackages.nagare pkgs.jq fakeNix fakePulumi fakeTools ]; }
              ''
                mkdir -p isolated/home isolated/config isolated/state isolated/empty
                export HOME="$PWD/isolated/home"
                export XDG_CONFIG_HOME="$PWD/isolated/config"
                export XDG_STATE_HOME="$PWD/isolated/state"
                export NAGARE_FAKE_TOOL_LOG="$PWD/isolated/tools.log"
                export LANG=C.UTF-8
                export LC_ALL=C.UTF-8
                touch "$NAGARE_FAKE_TOOL_LOG"
                cd isolated/empty

                nagarectl context create local \
                  --mode local \
                  --registry-host localhost:5000 \
                  --base-domain 127-0-0-1.sslip.io \
                  --local-object-store http://minio:9000/nagare-backups
                nagarectl context use local
                if nagarectl platform root --json > root.json 2> root.err; then
                  :
                else
                  platform_root_status="$?"
                  echo "nagarectl platform root exited with status $platform_root_status" >&2
                  cat root.err >&2
                  test ! -s root.json || cat root.json >&2
                  exit "$platform_root_status"
                fi
                jq -e '.source == "installed" and (.workspaceRoot | type == "string" and length > 0)' root.json >/dev/null || {
                  echo "nagarectl platform root returned unexpected JSON:" >&2
                  cat root.json >&2
                  exit 1
                }
                workspace_root="$(jq -er '.workspaceRoot' root.json)"
                test -f "$workspace_root/cluster/examples/uploads-volume/nagare/Config.hs"
                test ! -e "$workspace_root/cluster/secrets"
                mkdir -p "$XDG_CONFIG_HOME/nagare/cluster-secrets/local"
                resolved_secrets="$({
                  export NAGARE_PLATFORM_ROOT="$workspace_root"
                  export NAGARE_WORKSPACE_ROOT="$workspace_root"
                  . "$workspace_root/scripts/lib/target.sh"
                  . "$workspace_root/scripts/lib/cluster-secrets.sh"
                  nagare_cluster_secrets_dir
                })"
                test "$resolved_secrets" = "$XDG_CONFIG_HOME/nagare/cluster-secrets/local"
                if bash "$workspace_root/cluster/observability/install.sh" > observability-missing-secret.out 2>&1; then
                  echo "observability unexpectedly accepted a missing grafana Secret" >&2
                  exit 1
                fi
                grep -q 'missing encrypted cluster secret:.*grafana-admin.yaml' observability-missing-secret.out
                # EP-112: the ACME contact is mandatory. Non-interactively, with
                # no --acme-email, `init` must refuse and name the flag; there is
                # no safe default for somebody's mailbox.
                if nagarectl init trial --project example --dry-run --skip-preflight \
                  > init-no-acme.out 2> init-no-acme.err; then
                  echo "nagarectl init unexpectedly accepted a missing ACME contact" >&2
                  cat init-no-acme.out init-no-acme.err >&2
                  exit 1
                fi
                grep -q -- '--acme-email' init-no-acme.err
                nagarectl init trial --project example --acme-email ops@example.com \
                  --dry-run --skip-preflight > init.out
                grep -q 'config set --stack trial nagare:machineType e2-standard-2' init.out
                grep -q 'config set --stack trial nagare:bootDiskType pd-balanced' init.out
                grep -q 'config set --stack trial nagare:bootDiskSizeGb 100' init.out
                grep -q 'config set --stack trial nagare:dataDiskSizeGb 100' init.out
                grep -q 'DRY RUN: would run:' init.out
                grep -q "$XDG_STATE_HOME/nagare/trial/platform/" init.out
                nagarectl server status --skip-vm > status.out
                nagare --list > recipes.out
                grep -q 'infra-preview' recipes.out
                nagare --dry-run infra-preview > recipe-dry-run.out 2>&1
                grep -q 'cd infra/pulumi && pulumi preview' recipe-dry-run.out
                nagare --dry-run infra-up > infra-up-dry-run.out 2>&1
                grep -q 'nagarectl infra guard' infra-up-dry-run.out
                nagare --dry-run local-smoke > local-smoke-dry-run.out 2>&1
                grep -q 'scripts/local-smoke.sh' local-smoke-dry-run.out
                # EP-112: the issuer is rendered to a FILE and applied from that
                # file, so a refusal cannot be swallowed by a pipeline (just runs
                # each recipe line under `sh -cu` with no pipefail).
                nagare --dry-run cluster-bootstrap > cluster-bootstrap-dry-run.out 2>&1
                grep -q 'render-context-template.sh' cluster-bootstrap-dry-run.out
                grep -q 'kubectl apply -f "$issuer"' cluster-bootstrap-dry-run.out
                grep -q -- '-C.*nagare/local/platform/' "$NAGARE_FAKE_TOOL_LOG"

                # A legacy context must be adopted explicitly. The command
                # reports observations, stamps the absent cluster marker, and
                # commits only this context's release pin.
                sed -i '/NAGARE_PLATFORM_VERSION=/d' "$XDG_CONFIG_HOME/nagare/contexts/local.env"
                nagarectl platform adopt --version 0.1.0 --yes --json > adopt.json
                jq -e '.adopted == true and .platformVersion == "0.1.0" and .observations.context == null' adopt.json >/dev/null
                grep -q 'NAGARE_PLATFORM_VERSION=0.1.0' "$XDG_CONFIG_HOME/nagare/contexts/local.env"

                # EP-108: planning from a different context pin stages the host
                # release, records all previews, and leaves the context unchanged.
                sed -i 's/NAGARE_PLATFORM_VERSION=0.1.0/NAGARE_PLATFORM_VERSION=0.0.0/' "$XDG_CONFIG_HOME/nagare/contexts/local.env"
                host_dir="$XDG_CONFIG_HOME/nagare/hosts/local"
                mkdir -p "$host_dir"
                cat > "$host_dir/flake.nix" <<'HOST_FLAKE'
                {
                  inputs.nagare.url = "path:/old/nagare/nixos";
                  # Generated by nagarectl 0.0.0; EP-108 updates only this input.
                  # Nagare platform version: 0.0.0
                  # Nagare source revision: old
                }
                HOST_FLAKE
                printf '%s\n' '{ ... }: { }' > "$host_dir/host.nix"
                printf '%s\n' 'token: ENC[AES256_GCM,data:test]' 'sops: {}' > "$host_dir/secrets.yaml"
                payload_root="$(jq -er '.payloadRoot' root.json)"
                nagarectl platform upgrade --to 0.1.0 --payload-root "$payload_root" --dry-run --json > upgrade.json
                jq -e '.state == "planned" and .previousVersion == "0.0.0" and .targetVersion == "0.1.0" and ([.phases[] | select(.state == "succeeded")] | length) == 3' upgrade.json >/dev/null
                grep -q 'NAGARE_PLATFORM_VERSION=0.0.0' "$XDG_CONFIG_HOME/nagare/contexts/local.env"

                # EP-113: `nagarectl context guard` refuses when the selected Pulumi
                # stack's gcp:project disagrees with the active context. This is the
                # preflight `just infra-up` / `just infra-preview` now run before
                # Pulumi is invoked at all. The ambient CLOUDSDK_CORE_PROJECT is set
                # to the context's own project so the guard's third source (gcloud's
                # configured project, which the fake gcloud answers with JSON) is not
                # consulted; the stack alone varies between the two runs.
                nagarectl context create guardcloud \
                  --project acme-prod \
                  --region us-west1 \
                  --zone us-west1-a \
                  --base-domain apps.acme.example
                export CLOUDSDK_CORE_PROJECT=acme-prod

                NAGARE_FAKE_STACK_PROJECT=acme-prod \
                  nagarectl --context guardcloud context guard > guard-ok.out 2> guard-ok.err
                grep -q 'context guard: guardcloud confined to project acme-prod (stack guardcloud)' guard-ok.out

                if NAGARE_FAKE_STACK_PROJECT=some-other-project \
                  nagarectl --context guardcloud context guard > guard-bad.out 2> guard-bad.err; then
                  echo "context guard accepted a stack targeting a foreign project" >&2
                  cat guard-bad.out guard-bad.err >&2
                  exit 1
                fi
                grep -q 'some-other-project' guard-bad.err
                grep -q 'acme-prod' guard-bad.err
                unset CLOUDSDK_CORE_PROJECT

                touch "$out"
              '';

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
              shellcheck --severity=error \
                scripts/*.sh \
                scripts/lib/*.sh \
                cluster/bootstrap/render-context-template.sh \
                cluster/bootstrap/auth-images/build-local-image.sh \
                cluster/bootstrap/nagare-access/build-image.sh \
                nixos/hosts/nagare-01/forge-credentials-refresh.sh
              touch "$out"
            '';

          # EP-113: the fail-closed GCS bucket-ownership assertion in
          # scripts/lib/target.sh. Bucket names are global, so "the bucket
          # exists" is not evidence that it is ours.
          bucket-ownership-guard = pkgs.runCommand "nagare-bucket-ownership-guard-test"
            {
              nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep ];
              src = ./.;
            }
            ''
              cd "$src"
              bash scripts/test-bucket-ownership-guard.sh
              touch "$out"
            '';

          # EP-113: the auth-plane image builders take their project only from the
          # active context, with no `gcloud config get-value project` fallback.
          image-build-guard = pkgs.runCommand "nagare-image-build-guard-test"
            {
              nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.rsync ];
              src = ./.;
            }
            ''
              cd "$src"
              bash scripts/test-image-build-guard.sh
              touch "$out"
            '';

          # EP-112: the cert-manager ClusterIssuer's ACME identity comes from the
          # active context, and the renderer refuses — with EMPTY stdout — rather
          # than inventing one.
          render-context-template = pkgs.runCommand "nagare-render-context-template-test"
            {
              nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
              src = ./.;
            }
            ''
              cd "$src"
              bash scripts/test-render-context-template.sh
              touch "$out"
            '';

          # EP-112: no personal address and no specific project id may reappear as
          # a default under cluster/bootstrap/, and the two Let's Encrypt directory
          # URLs — which are deliberately duplicated between the shell resolver and
          # the Haskell one — may not drift apart.
          cluster-bootstrap-defaults = pkgs.runCommand "nagare-cluster-bootstrap-defaults"
            { nativeBuildInputs = [ pkgs.gnugrep pkgs.gnused pkgs.findutils ]; src = ./.; }
            ''
              cd "$src"
              # No specific project id and no email-shaped literal may appear as a
              # value in anything under cluster/bootstrap/. Comment lines are
              # skipped so illustrative addresses in documentation comments stay
              # legal; *.md files are out of scope (IR-3 scopes this guard to the
              # rendered assets).
              #
              # Addresses at the RFC 2606 / RFC 6761 reserved example domains
              # (example.com/.org/.net and any *.example) are ERASED before
              # matching rather than skipped by line: those names are reserved
              # forever and can never be a real person's mailbox, and the
              # renderer's own refusal message has to print one to tell an
              # operator what a contact looks like. Erasing the address rather
              # than exempting the whole line keeps a real address on the same
              # line detectable. The surviving file:line prefix still points at
              # the offending line.
              offenders="$(find cluster/bootstrap -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.tmpl' \) \
                -exec grep -Hn -v '^[[:space:]]*#' {} + \
                | sed -E 's/[A-Za-z0-9._%+-]+@(example\.(com|org|net)|[A-Za-z0-9.-]+\.example)([^A-Za-z0-9.-]|$)/\3/g' \
                | grep -E 'tan-nb-exp|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || true)"
              if [ -n "$offenders" ]; then
                echo "cluster/bootstrap must not carry a personal address or a specific project id:" >&2
                echo "$offenders" >&2
                exit 1
              fi

              # The two ACME directory URLs live in exactly two places: the shell
              # resolver and the Haskell resolver. Anywhere else is drift waiting
              # to happen — excepting the two test files that assert on them and
              # this file, which has to name them to perform this very check.
              for url in \
                https://acme-v02.api.letsencrypt.org/directory \
                https://acme-staging-v02.api.letsencrypt.org/directory; do
                grep -qF "$url" scripts/lib/target.sh || {
                  echo "missing $url in scripts/lib/target.sh" >&2
                  exit 1
                }
                grep -qF "$url" cli/nagarectl/src/Nagare/Target.hs || {
                  echo "missing $url in cli/nagarectl/src/Nagare/Target.hs" >&2
                  exit 1
                }
                stray="$(grep -rlF "$url" \
                  --include='*.sh' --include='*.hs' --include='*.nix' --include='*.yaml' --include='*.tmpl' \
                  . \
                  | grep -v -e '^\./scripts/lib/target\.sh$' \
                          -e '^\./cli/nagarectl/src/Nagare/Target\.hs$' \
                          -e '^\./scripts/test-render-context-template\.sh$' \
                          -e '^\./cli/nagarectl/test/Spec\.hs$' \
                          -e '^\./flake\.nix$' || true)"
                if [ -n "$stray" ]; then
                  echo "$url is duplicated outside the two resolvers:" >&2
                  echo "$stray" >&2
                  exit 1
                fi
              done
              touch "$out"
            '';

          forge-credential-refresh = pkgs.runCommand "nagare-forge-credential-refresh-test"
            {
              nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.jq pkgs.openssl ];
              src = ./.;
            }
            ''
              cd "$src"
              bash scripts/test-forge-credentials-refresh.sh
              touch "$out"
            '';

          release-consistency-source = pkgs.runCommand "release-consistency-source"
            { nativeBuildInputs = [ pkgs.bash pkgs.git pkgs.jq ]; src = ./.; }
            ''
              cp -R "$src" source
              chmod -R u+w source
              cd source
              bash ./scripts/test-release.sh
              touch "$out"
            '';

          github-actions = pkgs.runCommand "github-actions"
            { nativeBuildInputs = [ pkgs.actionlint ]; src = ./.; }
            ''
              actionlint "$src/.github/workflows/"*.yml
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
              pkgs.ast-grep
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
              pkgs.haskell.packages.ghc912.fourmolu
              pkgs.haskell.packages.ghc912.cabal-gild
              pkgs.ast-grep
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
