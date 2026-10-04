#!/usr/bin/env bash
# C2 rerun chain for 7d486457: bootstrap, C1, scenario (staged evidence), runner last, finalize, assemble.
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad; D=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/c2-7596; L=$D/logs; mkdir -p $L
ROOT=$(cat $S/c2-root); REPO=/Users/shinzui/Keikaku/bokuno/nagare
run() { local name=$1 marker=$2; shift 2; echo "## $(date -u +%H:%M:%S) $name"; "$@" > $L/$name.log 2>&1; rc=$?
  if [ $rc != 0 ] || ! grep -q "$marker" $L/$name.log; then echo "CHAIN STOPPED at $name rc=$rc"; tail -5 $L/$name.log; exit 1; fi; echo "   ok"; }
run su SU-OK bash $D/phase3-su.sh
run final-a FINAL-A-OK bash $D/phase3-final-a.sh
run final-b 'with 16 recorded assertions' bash $D/phase3-final-b.sh
EV=$ROOT/evidence/c2-7596632c
cp /private/tmp/nagare-release-7596632c/coverage.json $ROOT/coverage-result.json
run assemble 'Assembled public inventory evidence' bash -c "cd /private/tmp/nagare-cand-7596632c-src && bash scripts/assemble-managed-resource-evidence.sh --release-manifest /private/tmp/nagare-release-7596632c/aarch64-darwin/nagare-release-0.4.0.json --system aarch64-darwin --rehearsal-dir $EV --private-store-export $ROOT/evidence-private/final-export --coverage-result $ROOT/coverage-result.json --output $EV/inventory-evidence.json"
grep -c -i -E '"[^"]*(password|credential|access.?token|private.?key|secret)[^"]*":' $EV/inventory-evidence.json || true
echo CHAIN-DONE
