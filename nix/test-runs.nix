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

      # The nagare-dsl test binary, likewise built but not run (EP-180 M8: a
      # mutation record of the DSL is proved against its own suite).
      dslTestBinary = hl.overrideCabal nagarePackages.checkedNagareDsl (old: {
        pname = "nagare-dsl-test-binary";
        checkPhase = ":";
        postInstall = (old.postInstall or "") + ''
          install -D dist/build/nagare-dsl-test/nagare-dsl-test "$out/libexec/nagare-dsl-test"
        '';
      });

      # suite is "nagarectl" or "nagare-dsl".
      testRun =
        { label
        , pattern
        , shards ? [ "0/1" ]
        , deep ? false
        , suite ? "nagarectl"
        }:
        let
          selected =
            if suite == "nagare-dsl" then {
              binary = "${dslTestBinary}/libexec/nagare-dsl-test";
              src = nagarePackages.haskellPackages.nagare-dsl.src;
            } else if suite == "nagarectl" then {
              binary = "${testBinary}/libexec/nagarectl-test";
              src = nagarePackages.haskellPackages.nagarectl.src;
            } else throw "testRun: unknown suite ${suite}";
        in
        pkgs.runCommand "${suite}-test-run-${label}" { } ''
          mkdir -p "$out"
          # The suite reads test/fixtures relative to the package directory.
          cp -r ${selected.src} "$TMPDIR/suite"
          chmod -R u+w "$TMPDIR/suite"
          cd "$TMPDIR/suite"
          # The sandbox has no locale; test names and fixtures carry UTF-8.
          export LANG=C.UTF-8 LC_ALL=C.UTF-8
          export GHC_ENVIRONMENT=-
          export PATH=${lib.makeBinPath [ nagarePackages.typedConfigRuntime pkgs.kubernetes-helm pkgs.openssl pkgs.jq pkgs.python3 pkgs.perl ]}:$PATH
          export HELM_CACHE_HOME="$TMPDIR/nagare-helm-cache"
          mkdir -p "$HELM_CACHE_HOME"
          ${lib.optionalString deep "export NAGARE_RECOVERY_MODEL_DEEP=1"}
          echo "test run ${label}: pattern ${lib.escapeShellArg pattern}, shards ${toString shards}, $(nproc) cores"
          shard_pids=()
          for spec in ${lib.escapeShellArgs shards}; do
            name="shard-''${spec/\//-of-}"
            : > "$out/$name.log"
            (
              start=$(date +%s)
              set +e
              NAGARE_RECOVERY_MODEL_SHARD="$spec" ${selected.binary} -p ${lib.escapeShellArg pattern} > "$out/$name.log" 2>&1
              code=$?
              echo "$spec exit=$code seconds=$(( $(date +%s) - start ))" >> "$out/status"
              echo "test run: $spec finished, exit $code"
            ) &
            shard_pids+=("$!")
          done
          # Once a minute: each violation's faults and invariant lines found
          # since the last pass, so a run can be triaged before it ends, then
          # each shard's latest progress line.
          declare -A seen
          report() {
            for log in "$out"/shard-*.log; do
              total=$(wc -l < "$log")
              [ "$total" -gt "''${seen[$log]:-0}" ] && sed -n "$(( ''${seen[$log]:-0} + 1 )),''${total}p" "$log" \
                | grep -aE '^recovery-model: violation: .*[|] (faults|violation): ' || true
              seen[$log]=$total
              echo "$(basename "$log" .log): $(grep -a '^recovery-model: \[' "$log" | tail -n 1)"
            done
          }
          running() { for pid in "''${shard_pids[@]}"; do kill -0 "$pid" 2>/dev/null && return 0; done; return 1; }
          while running; do
            sleep 60
            report
          done
          wait "''${shard_pids[@]}"
          report
        '';
    in
    {
      legacyPackages = { inherit dslTestBinary testBinary testRun; };
    };
}
