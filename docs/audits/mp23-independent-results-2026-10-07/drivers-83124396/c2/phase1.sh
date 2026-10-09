#!/usr/bin/env bash
# C2 phase 1 for 7d486457: bootstrap stages 1-2, seed the five pinned images, stage-3 platform review.
set -uo pipefail
export DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad
ROOT=$(cat $S/c2-root); cd $ROOT
for n in ${PHASE1_STAGES-1 2}; do
  ./runctl.sh platform bootstrap plan --out $ROOT/reviews/bootstrap-$n > reviews/bootstrap-$n.log 2>&1 || { echo "PHASE1 FAILED plan $n: $(tail -2 reviews/bootstrap-$n.log)"; exit 1; }
  timeout 900 ./runctl.sh platform bootstrap apply $ROOT/reviews/bootstrap-$n --yes > reviews/bootstrap-$n-apply.log 2>&1; rc=$?
  echo "stage $n exit=$rc $(tail -1 reviews/bootstrap-$n-apply.log)"; [ $rc = 0 ] || { echo "PHASE1 FAILED stage $n"; exit 1; }
done
sleep 5
# The registry-pre-c2 OCI export was purged by macOS tmp cleanup (2026-10-08). Seed the same five
# components from the cp3 Docker image store instead: docker push of a containerd-store image
# reproduces its index digest, which is what images.env pins for this run.
for pair in en:k3d-registry.localhost:5000/en:9577009:1c85fea6b754ee03ca0e153d52375625f97126fc8c79656ece6dd2a73be31f8a shomei:k3d-registry.localhost:5000/shomei:9577009:cdd4de544b4fafbe5ba53bb8863214fc4d042ee6da295b108da58bf0776ec644 nagare-access:k3d-registry.localhost:5000/nagare-access:9577009:66f8bba4b4e9efd5e67feb6e929b9cd567050a00e63e13d3f49e2f7555e3cb2a nagare-minio:k3d-registry.localhost:5000/nagare-minio:release-2025-09-07-arm64:2fa8e93cd90597906a03f0f0182d87fcdfd2cbec1f48947b9550bb0eb6fc5990 nagare-mc:k3d-registry.localhost:5000/nagare-mc:release-2025-08-13-arm64:8510e21b6b6b6dda17c4d17b5b0be0e639096625d24a5c60656c2d438d31adff; do
  repo="${pair%%:*}"; rest="${pair#*:}"; want="${rest##*:}"; src="${rest%:*}"
  docker tag "$src" "localhost:5000/${repo}:c2-seed" && docker push --quiet "localhost:5000/${repo}:c2-seed" > /dev/null || { echo "PHASE1 FAILED push $repo"; exit 1; }
  got=$(skopeo --policy /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad/c2-83124396/oci-policy.json inspect --raw --tls-verify=false "docker://127.0.0.1:15013/${repo}@sha256:${want}" | shasum -a 256 | cut -c1-64)
  [ "$got" = "$want" ] && echo "$repo DIGEST-OK" || { echo "PHASE1 FAILED $repo digest $got"; exit 1; }
done
source images.env
./runctl.sh platform bootstrap plan --out $ROOT/reviews/bootstrap-3 > reviews/bootstrap-3.log 2>&1 || { echo "PHASE1 FAILED plan3: $(tail -2 reviews/bootstrap-3.log)"; exit 1; }
python3 -c "
import json,collections;d=json.load(open('$ROOT/reviews/bootstrap-3/review.json'));ops=d['operations'];print('plan3', len(ops),dict(collections.Counter(o['operation']['executor'] for o in ops)))"
TX=tx-$(tail -1 reviews/bootstrap-3.log)
L=reviews/bootstrap-3-apply.log; date -u +%H:%M:%S > $L
./runctl.sh platform bootstrap apply $ROOT/reviews/bootstrap-3 --yes >> $L 2>&1; echo "apply exit=$?" >> $L
for i in 1 2 3 4 5 6; do
  tail -2 $L | grep -q '^converged\|exit=0' && break
  grep -q 'ambiguous' <(tail -2 $L) || break
  sleep 20; echo "== resume $i $(date -u +%H:%M:%S)" >> $L
  ./runctl.sh inventory resume $TX --yes >> $L 2>&1; echo "resume exit=$?" >> $L
done
date -u +%H:%M:%S >> $L; cat $L
grep -q '^converged' $L && echo PHASE1-OK || echo "PHASE1 FAILED stage 3"
