{ pkgs, nagarePackages, src }:

{
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
