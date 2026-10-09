#!/usr/bin/env bash
# C2 rerun chain for 7d486457: bootstrap, C1, scenario (staged evidence), runner last, finalize, assemble.
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad; D=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad/c2-83124396; L=$D/logs; mkdir -p $L
ROOT=$(cat $S/c2-root); REPO=/private/tmp/nagare-cand-83124396-src
run() { local name=$1 marker=$2; shift 2; echo "## $(date -u +%H:%M:%S) $name"; "$@" > $L/$name.log 2>&1; rc=$?
  if [ $rc != 0 ] || ! grep -q "$marker" $L/$name.log; then echo "CHAIN STOPPED at $name rc=$rc"; tail -5 $L/$name.log; exit 1; fi; echo "   ok"; }
[ "${SKIP_PHASE1:-0}" = 1 ] || run phase1 PHASE1-OK bash $D/phase1.sh
PAY=$(basename $(ls -d $ROOT/state/nagare/local/platform/nagare-0.4.0-831243962c6b-*))
run c1 acceptedScopeContentDigestsUnchanged bash -c "source $ROOT/images.env && cd $REPO && python3 scripts/run-local-candidate-gate.py --operator-root $ROOT --wrapper $ROOT/runctl.sh --revision 83124396 --payload ${PAY%-*} --evidence-dir $ROOT/candidate-83124396-c1"
jq -c '{operations, actions, providerMutations, acceptedScopeContentDigestsUnchanged}' $ROOT/candidate-83124396-c1/proof.json
# F49 side effect: a clean context must show no replaced-incarnation finding.
run noreplaced-after-c1 ZERO-REPLACED bash -c "cd \$(cat $S/c2-root) && n=\$(./runctl.sh inventory status --json 2>/dev/null | jq '[.findings[]? | select(.category == \"replaced-incarnation\")] | length') && echo replaced=\$n && [ \"\$n\" = 0 ] && echo ZERO-REPLACED"
run phase2 PHASE2-OK bash $D/phase2.sh
run phase2b PHASE2B-OK bash $D/phase2b.sh
run rebind-check REBIND-CHECK-OK bash /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad/c2-83124396/rebind-check.sh
run restores RESTORES-OK bash $D/phase3-restores.sh
run misc MISC-OK bash $D/phase3-misc.sh
run su SU-OK bash $D/phase3-su.sh
run final-a FINAL-A-OK bash $D/phase3-final-a.sh
run retire-kept RETIRE-KEPT-OK bash $D/retire-kept.sh
run noreplaced-before-runner ZERO-REPLACED bash -c "cd \$(cat /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad/c2-root) && n=\$(./runctl.sh inventory status --json 2>/dev/null | jq '[.findings[]? | select(.category == \"replaced-incarnation\")] | length') && echo replaced=\$n && [ \"\$n\" = 0 ] && echo ZERO-REPLACED"
run settle-workloads SETTLED bash -c "KUBECONFIG=$(cat $S/c2-root)/config/nagare/kubeconfigs/local.yaml kubectl --context local wait --for=condition=Available deployment --all -n nagare-system --timeout=600s && echo SETTLED"
run final-b 'with 16 recorded assertions' bash $D/phase3-final-b.sh
EV=$ROOT/evidence/c2-83124396
cp /private/tmp/nagare-release-83124396/coverage.json $ROOT/coverage-result.json
run assemble 'Assembled public inventory evidence' bash -c "cd /private/tmp/nagare-cand-83124396-src && bash scripts/assemble-managed-resource-evidence.sh --release-manifest /private/tmp/nagare-release-83124396/aarch64-darwin/nagare-release-0.4.0.json --system aarch64-darwin --rehearsal-dir $EV --private-store-export $ROOT/evidence-private/final-export --coverage-result $ROOT/coverage-result.json --output $EV/inventory-evidence.json"
grep -c -i -E '"[^"]*(password|credential|access.?token|private.?key|secret)[^"]*":' $EV/inventory-evidence.json || true
echo CHAIN-DONE
