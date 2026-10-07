{ self, ... }:

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

      # EP-180 M8: a sweep of every mutation record at one revision. Rebuilding
      # the test binary per record with Nix costs a full build each (about five
      # minutes), so the sweep compiles the revision once per worker with cabal,
      # at -O0 so a mutation inside a function body changes only its own
      # module's interface, then per record: patch, rebuild incrementally, run
      # the record's pattern, revert. Like testRun it never fails on a record's
      # result; results.tsv holds, per record, whether it applied and built and
      # its test exit code, and nagare-harness classifies them.
      hp = nagarePackages.haskellPackages;
      cabalDeps = package:
        let deps = package.getCabalDeps;
        in (deps.libraryHaskellDepends or [ ]) ++ (deps.executableHaskellDepends or [ ])
          ++ (deps.testHaskellDepends or [ ]) ++ (deps.benchmarkHaskellDepends or [ ]);
      localPackages = [ "nagare-dsl" "nagarectl" ];
      sweepGhc = hp.ghcWithPackages (_: lib.filter
        (dep: dep != null && !(lib.elem (dep.pname or "") localPackages))
        (cabalDeps hp.nagarectl ++ cabalDeps nagarePackages.checkedNagareDsl));

      # The sweep's project file is the real cabal.project less its
      # source-repository-package stanzas (their packages are already in
      # sweepGhc, and the sandbox cannot fetch them). Any top-level stanza the
      # generator does not know fails the sweep, so the two cannot drift.
      sweepProject = pkgs.writeText "sweep-cabal-project.py" ''
        import re, sys
        known = {"write-ghc-environment-files", "packages", "allow-newer", "constraints", "package", "source-repository-package"}
        out, skipping = [], False
        for line in open(sys.argv[1]):
            if line.startswith("--") or not line.strip():
                if not skipping:
                    out.append(line)
                continue
            if not line[0].isspace():
                key = re.split(r"[:\s]", line.strip(), maxsplit=1)[0]
                if key not in known:
                    sys.exit("cabal.project: the sweep does not understand the stanza " + key)
                skipping = key == "source-repository-package"
            if not skipping:
                out.append(line)
        sys.stdout.write("".join(out))
      '';

      mutationSweep =
        { label
        , width ? 4
        }:
        pkgs.runCommand "mutation-sweep-${label}" { nativeBuildInputs = [ sweepGhc pkgs.cabal-install pkgs.jq pkgs.python3 pkgs.coreutils ]; } ''
          set -uo pipefail
          mkdir -p "$out/logs"
          export HOME="$TMPDIR/home" CABAL_DIR="$TMPDIR/cabal"
          mkdir -p "$HOME" "$CABAL_DIR"
          : > "$CABAL_DIR/config"
          export LANG=C.UTF-8 LC_ALL=C.UTF-8 GHC_ENVIRONMENT=-
          # The loader tests' runghc must be typedConfigRuntime's, as in the
          # shipped test run; the build names sweepGhc explicitly.
          export PATH=${lib.makeBinPath [ nagarePackages.typedConfigRuntime pkgs.kubernetes-helm pkgs.openssl pkgs.perl ]}:$PATH
          export HELM_CACHE_HOME="$TMPDIR/nagare-helm-cache"
          mkdir -p "$HELM_CACHE_HOME"
          python3 ${sweepProject} ${self}/cli/nagarectl/cabal.project > "$TMPDIR/cabal.project.sweep" || exit 1
          jq -r '.[] | [.record, .suite, .pattern] | @tsv' ${self}/cli/nagarectl/test/mutations/records.json > "$TMPDIR/records.tsv"
          width=${toString width}
          jobs=$(( $(nproc) / width )); [ "$jobs" -ge 1 ] || jobs=1
          echo "mutation sweep ${label}: $(wc -l < "$TMPDIR/records.tsv") records, $width workers, -j$jobs each, $(nproc) cores"
          worker() {
            local w=$1 tree="$TMPDIR/tree-$1" n=0 record suite pattern
            cp -R ${self} "$tree"
            chmod -R u+w "$tree"
            patchShebangs "$tree/cluster" > /dev/null
            cp "$TMPDIR/cabal.project.sweep" "$tree/cli/nagarectl/cabal.project.sweep"
            cd "$tree/cli/nagarectl"
            build() { cabal build --offline --enable-tests -w ${sweepGhc}/bin/ghc -O0 -j"$jobs" --project-file=cabal.project.sweep nagarectl-test nagare-dsl-test; }
            local start=$(date +%s)
            if ! build > "$out/logs/base-$w.log" 2>&1; then
              echo "worker $w: base build failed" | tee -a "$out/status"
              return
            fi
            echo "worker $w: base built in $(( $(date +%s) - start ))s" | tee -a "$out/status"
            while IFS=$'\t' read -r record suite pattern; do
              n=$(( n + 1 ))
              [ $(( (n - 1) % width )) -eq "$w" ] || continue
              local diff="$tree/cli/nagarectl/test/mutations/$record.diff" log="$out/logs/$record.log" began=$(date +%s)
              if ! patch -p1 -d "$tree" < "$diff" > "$log" 2>&1; then
                printf '%s\tstale\t\t0\n' "$record" >> "$out/results-$w.tsv"
                continue
              fi
              if build >> "$log" 2>&1; then
                local binary dir
                binary=$(cabal list-bin --offline --enable-tests -w ${sweepGhc}/bin/ghc -O0 --project-file=cabal.project.sweep "$suite-test" 2>> "$log")
                dir="$tree/cli/$suite"
                (cd "$dir" && timeout 1800 "$binary" -p "$pattern") >> "$log" 2>&1
                printf '%s\tbuilt\t%s\t%s\n' "$record" "$?" "$(( $(date +%s) - began ))" >> "$out/results-$w.tsv"
              else
                printf '%s\tbuild-failed\t\t%s\n' "$record" "$(( $(date +%s) - began ))" >> "$out/results-$w.tsv"
              fi
              patch -R -p1 -d "$tree" < "$diff" >> "$log" 2>&1
            done < "$TMPDIR/records.tsv"
            echo "worker $w: done" | tee -a "$out/status"
          }
          pids=()
          for w in $(seq 0 $(( width - 1 ))); do
            worker "$w" &
            pids+=("$!")
          done
          wait "''${pids[@]}"
          cat "$out"/results-*.tsv > "$out/results.tsv" 2> /dev/null || : > "$out/results.tsv"
        '';
    in
    {
      legacyPackages = { inherit dslTestBinary mutationSweep testBinary testRun; };
    };
}
