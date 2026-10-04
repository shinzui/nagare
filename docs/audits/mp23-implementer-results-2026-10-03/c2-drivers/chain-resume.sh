#!/usr/bin/env bash
# Resume the 7d486457 C2 rerun after the refused preview collect: final-a (resume), final-b, assemble.
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad; D=$S/rerun; L=$D/logs
ROOT=$(cat $S/c2-root)
run() { local name=$1 marker=$2; shift 2; echo "## $(date -u +%H:%M:%S) $name"; "$@" > $L/$name.log 2>&1; rc=$?
  if [ $rc != 0 ] || ! grep -q "$marker" $L/$name.log; then echo "CHAIN STOPPED at $name rc=$rc"; tail -5 $L/$name.log; exit 1; fi; echo "   ok"; }
run final-a-resume FINAL-A-OK bash $D/phase3-final-a-resume.sh
run final-b 'with 16 recorded assertions' bash $D/phase3-final-b.sh
EV=$ROOT/evidence/c2-7d486457
cp $S/coverage-7d48.json $ROOT/coverage-result.json
run assemble 'Assembled public inventory evidence' bash -c "cd /private/tmp/nagare-pre-7d486457-src && bash scripts/assemble-managed-resource-evidence.sh --release-manifest /private/tmp/nagare-release-7d486457/aarch64-darwin/nagare-release-0.4.0.json --system aarch64-darwin --rehearsal-dir $EV --private-store-export $ROOT/evidence-private/final-export --coverage-result $ROOT/coverage-result.json --output $EV/inventory-evidence.json"
echo "secret-shaped keys: $(grep -c -i -E '"[^"]*(password|credential|access.?token|private.?key|secret)[^"]*":' $EV/inventory-evidence.json)"
echo CHAIN-DONE
