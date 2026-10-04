#!/usr/bin/env bash
# C2 phase 1 for 7d486457: bootstrap stages 1-2, seed the five pinned images, stage-3 platform review.
set -uo pipefail
export DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad
ROOT=$(cat $S/c2-root); cd $ROOT
for n in 1 2; do
  ./runctl.sh platform bootstrap plan --out $ROOT/reviews/bootstrap-$n > reviews/bootstrap-$n.log 2>&1 || { echo "PHASE1 FAILED plan $n: $(tail -2 reviews/bootstrap-$n.log)"; exit 1; }
  timeout 900 ./runctl.sh platform bootstrap apply $ROOT/reviews/bootstrap-$n --yes > reviews/bootstrap-$n-apply.log 2>&1; rc=$?
  echo "stage $n exit=$rc $(tail -1 reviews/bootstrap-$n-apply.log)"; [ $rc = 0 ] || { echo "PHASE1 FAILED stage $n"; exit 1; }
done
sleep 5
R=/private/tmp/nagare-mp23-cp3.1EQ78L; B=$R/exports/registry-pre-c2
for pair in en:636575a0342bd552761d4b0fa631f14a2e2f691e42d55567087f5497618f9768 shomei:0ba0c4f2e58a294252ce950257b688dea6d8f54f3b6d23f26df59298084e2c7c nagare-access:9ca05a65ee7daa4684b76afa7eadb06b55ab31e0d9055a43aec98b24cbba228e nagare-minio:b472b80c4cf0caaedaa4ce8ae6554f21985f66bc0cebd8c22a00a271e5a1db6c nagare-mc:d7de6dcc1015cdba1e72abf68bd0daf3f525ed597cb7c21181c7f73e952420b8; do
  repo="${pair%%:*}"; want="${pair#*:}"
  skopeo --policy $R/oci-policy.json copy --quiet --dest-tls-verify=false --preserve-digests "oci:${B}:${repo}" "docker://127.0.0.1:15013/${repo}:c2-7d48" || { echo "PHASE1 FAILED push $repo"; exit 1; }
  got=$(skopeo --policy $R/oci-policy.json inspect --raw --tls-verify=false "docker://127.0.0.1:15013/${repo}@sha256:${want}" | shasum -a 256 | cut -c1-64)
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
