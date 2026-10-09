#!/usr/bin/env bash
# After the operator approves the Tailscale SSH check: settle the stage-7 transaction by the documented
# exit, finish the bootstrap, run C3, then the section 3 and section 4 drills. Stops at the first failure.
M=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; LOG=$M/continuation.log; cd $M
log() { echo "$(date -u +%FT%TZ) $*" | tee -a $LOG; }
export CLOUDSDK_ACTIVE_CONFIG_NAME=labs CLOUDSDK_CORE_PROJECT=tan-ng-labs
head_field() { local v; v=$(gcloud storage cat gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory/head.json | jq -r ".$1") || return 1; [ -n "$v" ] || return 1; echo "$v"; }
until gcloud storage cat gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory/head.json > /dev/null 2>&1; do sleep 30; done
log "gcloud credentials valid"
log "Tailscale SSH check approved: $(grep APPROVED $M/ts-probe.out | tail -1)"
TX=$(head_field activeTransaction) || { log "STOPPED: cannot read inventory head"; exit 1; }
if [ "$TX" != null ]; then
  ./runctl.sh inventory resume $TX --yes > $M/evidence/s7-resume.txt 2>&1; rc=$?; log "resume $TX exit=$rc: $(grep -v -i warning $M/evidence/s7-resume.txt | tail -2 | tr '\n' ' ' | cut -c1-300)"
  TX2=$(head_field activeTransaction) || { log "STOPPED: cannot read inventory head"; exit 1; }
  if [ "$TX2" != null ]; then
    ./runctl.sh inventory close $TX2 --review $(cut -c1-64 $M/evidence/s7-stage/review/review.sha256) > $M/evidence/s7-close.txt 2>&1; rc=$?
    log "close exit=$rc: $(grep -v -i warning $M/evidence/s7-close.txt | tail -4 | tr '\n' ' ' | cut -c1-400)"
    [ $rc = 0 ] || { log "STOPPED: close refused"; exit 1; }
    START=7
  else
    START=8
  fi
  mv $M/evidence/s7-stage $M/evidence/s7-stage.attempt1
else
  START=7; mv $M/evidence/s7-stage $M/evidence/s7-stage.attempt1
fi
START=$START bash $M/bootstrap-loop.sh > $M/evidence/bootstrap-loop-2.out 2>&1; echo "loop exit=$?" >> $M/evidence/bootstrap-loop-2.out
cat $M/evidence/bootstrap-loop.out $M/evidence/bootstrap-loop-2.out > $M/evidence/bootstrap-loop.all
cp $M/evidence/bootstrap-loop-2.out $M/evidence/bootstrap-loop.out
log "bootstrap: $(tail -2 $M/evidence/bootstrap-loop-2.out | tr '\n' ' ')"
bash $M/after-bootstrap.sh > $M/after-bootstrap.out 2>&1; log "C3: $(tail -1 $M/after-bootstrap.out)"
grep -q CHAIN-DONE $M/c3-chain.log || { log "STOPPED after C3"; exit 1; }
bash $M/s3-run.sh > $M/s3/run.log 2>&1; log "section 3: $(tail -1 $M/s3/run.log | cut -c1-300)"
grep -q S3-ALL-OK $M/s3/run.log || { log "STOPPED in section 3"; exit 1; }
bash $M/s4-run.sh > $M/s4/run.log 2>&1; log "section 4: $(tail -1 $M/s4/run.log | cut -c1-300)"
grep -q S4-ALL-OK $M/s4/run.log || { log "STOPPED in section 4"; exit 1; }
log "CONTINUATION-DONE"
