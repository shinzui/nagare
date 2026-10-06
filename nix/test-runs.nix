{ ... }:

# Heavy nagarectl test runs (the recovery model's deep tier, scenario reruns,
# timing) run as Nix builds, so an x86_64-linux run executes on the remote
# builder instead of the operator's machine (operator decision, 2026-10-06).
# `just test-remote` builds `legacyPackages.x86_64-linux.testRun { ... }` from
# an exact commit. Each shard runs the nagarectl test binary in parallel with
# its own NAGARE_RECOVERY_MODEL_SHARD; the run never fails the build, so a
# failing or slow shard still leaves its log, and `status` holds each shard's
# exit code and seconds.
{
  perSystem = { pkgs, nagarePackages, ... }:
    let
      inherit (pkgs) lib;
      hl = pkgs.haskell.lib;

      # The shipped nagarectl derivation with its test suite built but not run,
      # and the test binary installed. It keeps the shipped derivation's
      # postPatch, so the binary reads the same store-path fixtures.
      testBinary = hl.overrideCabal nagarePackages.haskellPackages.nagarectl (old: {
        pname = "nagarectl-test-binary";
        doCheck = true;
        checkPhase = ":";
        postInstall = (old.postInstall or "") + ''
          install -D dist/build/nagarectl-test/nagarectl-test "$out/libexec/nagarectl-test"
        '';
      });

      testRun =
        { label
        , pattern
        , shards ? [ "0/1" ]
        , deep ? false
        }:
        pkgs.runCommand "nagarectl-test-run-${label}" { } ''
          mkdir -p "$out"
          # The suite reads test/fixtures relative to the package directory.
          cp -r ${nagarePackages.haskellPackages.nagarectl.src} "$TMPDIR/nagarectl"
          chmod -R u+w "$TMPDIR/nagarectl"
          cd "$TMPDIR/nagarectl"
          # The sandbox has no locale; test names and fixtures carry UTF-8.
          export LANG=C.UTF-8 LC_ALL=C.UTF-8
          export GHC_ENVIRONMENT=-
          export PATH=${lib.makeBinPath [ nagarePackages.typedConfigRuntime pkgs.kubernetes-helm pkgs.openssl pkgs.jq pkgs.python3 pkgs.perl ]}:$PATH
          export HELM_CACHE_HOME="$TMPDIR/nagare-helm-cache"
          mkdir -p "$HELM_CACHE_HOME"
          ${lib.optionalString deep "export NAGARE_RECOVERY_MODEL_DEEP=1"}
          echo "test run ${label}: pattern ${lib.escapeShellArg pattern}, shards ${toString shards}, $(nproc) cores"
          for spec in ${lib.escapeShellArgs shards}; do
            name="shard-''${spec/\//-of-}"
            (
              start=$(date +%s)
              set +e
              NAGARE_RECOVERY_MODEL_SHARD="$spec" ${testBinary}/libexec/nagarectl-test -p ${lib.escapeShellArg pattern} > "$out/$name.log" 2>&1
              code=$?
              echo "$spec exit=$code seconds=$(( $(date +%s) - start ))" >> "$out/status"
              echo "test run: $spec finished, exit $code"
            ) &
          done
          # Keep the build log alive and show progress: each shard's latest
          # recovery-model line, once a minute.
          while [ -n "$(jobs -r)" ]; do
            sleep 60
            for log in "$out"/shard-*.log; do
              [ -e "$log" ] && echo "$(basename "$log" .log): $(grep -a '^recovery-model:' "$log" | tail -n 1)"
            done
          done
          wait
        '';
    in
    {
      legacyPackages = { inherit testBinary testRun; };
    };
}
