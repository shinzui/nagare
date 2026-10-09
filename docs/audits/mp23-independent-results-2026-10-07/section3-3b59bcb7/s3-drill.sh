#!/usr/bin/env bash
# Checklist section 3 drill on mp23-c3l (candidate 3b59bcb7), following
# docs/user/day-2-host-changes.md "Upgrade NixOS and k3s".
# Phases (in order): snap0 backup fail-a apply-b backup-c apply-c (B and C finish with a reviewed stop/start reboot)
#   fail-a   re-pin to REV_A (same k3s minor); the apply's transport shell is stopped by exact PID after
#            the remote activation starts (no fresh-login check, no commit); the on-host timer reverts;
#            resume must refuse; close must accept nothing (no effect).
#   apply-b  the same re-pin, reviewed again and applied normally.
#   apply-c  the next k3s minor (REV_C), forward only, after a fresh backup proven by its restore.
set -uo pipefail
K=/Users/shinzui/.local/state/nagare-verify/mp23-c3l; RUN=$K/runctl.sh; HC=$K/hostcmd.sh
W=$K/s3; E=$W/evidence; R=$W/reviews; mkdir -p $E $R
HF=$K/config/nagare/hosts/mp23-c3l; NS=personal
REV_A=b1b875982b17dabde9b4a37f3e229e74913e6db3; REV_C=e7439b6b14ad3cc35d05608ebca9bce01a25f5f8
export KUBECONFIG=$K/config/nagare/kubeconfigs/mp23-c3l.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs
K8() { command kubectl --context mp23-c3l "$@"; }
die() { echo "S3 FAILED [$PH]: $*" | tee -a $E/timeline.txt; exit 1; }
log() { echo "== $(date -u +%FT%TZ) $*" | tee -a $E/timeline.txt; }
q() { grep -v -E '^\s*warning|^context guard|^platform mutation' "$1" | tail -${2:-2} | tr '\n' ' ' | cut -c1-400; }
host() { timeout 180 $HC "$@" 2>/dev/null | grep -v -i warning; }
idle() { [ "$($RUN inventory status --json 2>/dev/null | jq -r .activeTransaction)" = null ]; }

# The ledger, application data, databases and host, as one comparable record.
snap() {
  local t=$1 d=$E/snap-$1; mkdir -p $d
  host 'printf "current=%s\n" "$(readlink -f /run/current-system)"; printf "timer=%s\n" "$(systemctl is-active nagare-switch-rollback.timer)"; printf "k3s=%s\n" "$(k3s --version | head -1)"; printf "kernel=%s\n" "$(uname -r)"; printf "boot=%s\n" "$(cat /proc/sys/kernel/random/boot_id)"' > $d/host.txt
  K8 get nodes -o json | jq -r '.items[] | "\(.metadata.name) ready=\(.status.conditions[] | select(.type=="Ready") | .status) kubelet=\(.status.nodeInfo.kubeletVersion) os=\(.status.nodeInfo.osImage) kernel=\(.status.nodeInfo.kernelVersion)"' > $d/nodes.txt
  K8 get pods -A -o json | jq -r '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"] | .[]' > $d/pods-not-running.txt
  $RUN inventory status --json > $d/status.json 2>/dev/null
  jq -c '{activeTransaction, findings: (.findings | length), categories: ([.findings[] | .category // empty] | group_by(.) | map({(.[0]): length}) | add)}' $d/status.json > $d/status-summary.json
  # Data: the PostgreSQL rows, the Redis keys and the ClickHouse rows the C3 scenario seeded.
  K8 -n $NS exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||chr(124)||v from scenario_known order by id"' > $d/pg.txt 2>&1
  K8 -n $NS exec scenario-redis-0 -c redis -- sh -c 'for k in $(redis-cli --no-auth-warning -a "$REDIS_PASSWORD" --scan --pattern "scenario:known:*" | sort); do echo "$k=$(redis-cli --no-auth-warning -a "$REDIS_PASSWORD" GET $k)"; done' > $d/redis.txt 2>&1
  K8 -n $NS exec scenario-ch-0 -- sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "select concat(toString(id), chr(124), v) from scenario_events order by id"' > $d/ch.txt 2>&1
  cat $d/pg.txt $d/redis.txt $d/ch.txt | shasum -a 256 | cut -c1-64 > $d/data.sha256
  # doctor checks every retained backup object serially (F92), so it runs only at the states the
  # checklist names: after the failed upgrade and after each upgrade's reboot.
  case " ${S3_DOCTOR_AT:-0 fail-a b-rebooted c-rebooted c-failed} " in
    *" $t "*) local t0=$(date +%s); timeout 1800 $RUN doctor > $d/doctor.txt 2>&1; echo "doctor exit=$? seconds=$(( $(date +%s) - t0 ))" >> $d/doctor.txt ;;
    *) echo "doctor skipped at this intermediate state" > $d/doctor.txt ;;
  esac
  log "snap $t: $(grep -o 'nixos-system[^ ]*' $d/host.txt | tail -c 40) $(grep -o 'v1\.[0-9.]*+k3s[0-9]' $d/host.txt) data=$(cut -c1-12 $d/data.sha256) pg=$(wc -l < $d/pg.txt) redis=$(wc -l < $d/redis.txt) ch=$(wc -l < $d/ch.txt) notRunning=$(wc -l < $d/pods-not-running.txt) $(tail -1 $d/doctor.txt) $(cat $d/status-summary.json | cut -c1-120)"
}
same_data() { cmp -s $E/snap-$1/data.sha256 $E/snap-$2/data.sha256 || die "data changed between $1 and $2"; }

# A fresh reviewed backup of every scenario database, one proven by an isolated restore.
backup() {
  local id=$1
  for db in scenario-pg scenario-redis scenario-ch; do
    $RUN db backup $db --backup-id $id --save-plan $R/backup-$db-$id > $R/backup-$db-$id.log 2>&1 && $RUN inventory apply $R/backup-$db-$id --yes >> $R/backup-$db-$id.log 2>&1 || die "backup $db: $(q $R/backup-$db-$id.log)"
  done
  K8 -n $NS exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||chr(124)||v from scenario_known order by id"' > $E/pg-at-$id.txt
  $RUN db restore scenario-pg $id --restore-id $id --save-plan $R/restore-$id > $R/restore-$id.log 2>&1 && $RUN inventory apply $R/restore-$id --yes >> $R/restore-$id.log 2>&1 || die "restore: $(q $R/restore-$id.log)"
  K8 -n $NS exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "scenario-pg_restore_'$id'" -tA -c "select id||chr(124)||v from scenario_known order by id"' > $E/pg-restored-$id.txt
  cmp -s $E/pg-at-$id.txt $E/pg-restored-$id.txt || die "restore $id differs from the source"
  log "backup $id: three databases backed up; scenario-pg restore = source ($(wc -l < $E/pg-restored-$id.txt) rows)"
}

SOPS=dcd241ba97088c22569d1573286e1b9daad340c0
repin() { # rev name: re-pin nagare/nixpkgs, and nagare/sops-nix (its pinned revision needs Go 1.25, removed
          # from current nixpkgs); prove nothing else in the lock moved and the host toplevel evaluates
  cp $HF/flake.lock $E/flake.lock.before-$2
  nix flake lock "path:$HF" --override-input nagare/nixpkgs "github:NixOS/nixpkgs/$1" --override-input nagare/sops-nix "github:Mic92/sops-nix/$SOPS" --override-input nagare/sops-nix/nixpkgs "github:NixOS/nixpkgs/$1" > $E/repin-$2.log 2>&1 || die "flake lock: $(tail -2 $E/repin-$2.log)"
  cp $HF/flake.lock $E/flake.lock.after-$2
  jq -S 'del(.nodes.nixpkgs, .nodes["sops-nix"], .nodes.nixpkgs_2)' $E/flake.lock.before-$2 > $E/l1; jq -S 'del(.nodes.nixpkgs, .nodes["sops-nix"], .nodes.nixpkgs_2)' $E/flake.lock.after-$2 > $E/l2
  [ "$(jq -r '.nodes.nixpkgs_2.locked.rev // $r' --arg r $1 $HF/flake.lock)" = "$1" ] || die "sops-nix nixpkgs is not pinned to $1"
  cmp -s $E/l1 $E/l2 || die "the re-pin moved more than nixpkgs and sops-nix"; rm -f $E/l1 $E/l2
  [ "$(jq -r .nodes.nixpkgs.locked.rev $HF/flake.lock)" = "$1" ] || die "lock does not name $1"
  [ "$(jq -r '.nodes["sops-nix"].locked.rev' $HF/flake.lock)" = "$SOPS" ] || die "lock does not name sops-nix $SOPS"
  local hn; hn=$($RUN host name 2>/dev/null | tail -1)
  nix eval --raw --no-update-lock-file "path:$HF#nixosConfigurations.$hn.config.system.build.toplevel.drvPath" > $E/eval-$2.txt 2> $E/eval-$2.err || die "host toplevel does not evaluate: $(grep -i error $E/eval-$2.err | head -2)"
  log "re-pinned nixpkgs $1 and sops-nix $SOPS ($2); only those nodes changed; toplevel evaluates: $(cat $E/eval-$2.txt)"
}
builder_up() { # the host build runs on the reused builder; planning refuses an implicit start (F24)
  [ "$(gcloud compute instances describe nix-builder-ep150 --zone us-west1-a --project tan-ng-labs --format='value(status)')" = RUNNING ] && return 0
  gcloud compute instances start nix-builder-ep150 --zone us-west1-a --project tan-ng-labs > /dev/null 2>&1 || die "builder start"
  sleep 45; log "started builder nix-builder-ep150"
}
plan() { # name
  builder_up
  $RUN host plan --save-plan $R/$1 > $R/$1.plan.log 2>&1 || die "host plan $1: $(q $R/$1.plan.log 3)"
  cp $R/$1.plan.log $E/review-$1.txt
  jq -c '[.operations[] | {a: .operation.action.tag, r: .operation.resources}]' $R/$1/review.json > $E/review-$1-ops.json
  log "planned $1: $(cut -c1-300 $E/review-$1-ops.json)"
}
apply() { # name
  timeout 3600 $RUN inventory apply $R/$1 --yes > $R/$1.apply.log 2>&1; local rc=$?
  cp $R/$1.apply.log $E/apply-$1.txt; log "apply $1 exit=$rc: $(q $R/$1.apply.log)"
  [ $rc = 0 ] || die "apply $1"
}
reboot() { # tag: reviewed VM power stop then start, then wait for the cluster and record
  local t=$1
  $RUN host stop --operation-id s3-stop-$t --save-plan $R/stop-$t > $R/stop-$t.log 2>&1 || die "stop plan: $(q $R/stop-$t.log)"; apply stop-$t
  $RUN host start --operation-id s3-start-$t --save-plan $R/start-$t > $R/start-$t.log 2>&1 || die "start plan: $(q $R/start-$t.log)"; apply start-$t
  for i in $(seq 1 60); do K8 get nodes -o json 2>/dev/null | jq -e '[.items[].status.conditions[] | select(.type=="Ready") | .status] | all(. == "True")' > /dev/null && break; sleep 10; done
  for i in $(seq 1 60); do [ "$(K8 get pods -A -o json 2>/dev/null | jq '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")] | length')" = 0 ] && break; sleep 10; done
  snap $t-rebooted
}
descendants() { local p; for p in $(ps -A -o pid=,ppid= | awk -v P=$1 '$2==P {print $1}'); do echo $p; descendants $p; done; }

PH=${1:?phase}
case $PH in
snap0) idle || die "transaction active"; snap 0 ;;
backup) idle || die "transaction active"; backup s3pre ;;
fail-a)
  idle || die "transaction active"
  repin $REV_A a; plan fail-a
  OLD=$(host 'readlink -f /run/current-system' | tail -1); echo "$OLD" > $E/fail-a-old-closure.txt
  log "apply fail-a with NAGARE_SWITCH_CONFIRM_SECONDS=120 (apply-time setting, not bound in the review)"
  NAGARE_SWITCH_CONFIRM_SECONDS=120 $RUN inventory apply $R/fail-a --yes > $R/fail-a.apply.log 2>&1 & APID=$!; echo $APID > $E/fail-a-apply-pid.txt
  STOPPED=""; for i in $(seq 1 7200); do
    kill -0 $APID 2>/dev/null || break
    for p in $(descendants $APID); do
      if ps -ww -o command= -p $p 2>/dev/null | grep -q -E '(^|/)ssh .*nagare-safe-activate activate /nix/store/'; then
        STOPPED=$(ps -o ppid= -p $p | tr -d ' '); SSHP=$p; kill -STOP $STOPPED; break 2
      fi
    done; sleep 0.25
  done
  [ -n "$STOPPED" ] || die "the activation step was never reached: $(q $R/fail-a.apply.log 3)"
  log "transport shell $STOPPED stopped while its activation ssh $SSHP ran (apply pid $APID); no fresh-login check or commit can follow"
  ps -o pid,ppid,stat,command -p $APID,$STOPPED,$SSHP | cut -c1-160 > $E/fail-a-process-tree.txt
  while kill -0 $SSHP 2>/dev/null && [ "$(ps -o stat= -p $SSHP | cut -c1)" != Z ]; do sleep 1; done
  log "remote activation returned"
  # The operator process dies now, inside the confirm window: kill exactly the processes this drill
  # started, deepest first.
  PIDS="$(descendants $APID | sort -rn) $APID"; echo "$PIDS" > $E/fail-a-killed-pids.txt
  for p in $PIDS; do kill -KILL $p 2>/dev/null; done; kill -CONT $STOPPED 2>/dev/null; wait $APID 2>/dev/null
  host 'printf "%s %s\n" "$(readlink -f /run/current-system)" "$(systemctl is-active nagare-switch-rollback.timer)"' | tail -1 > $E/fail-a-host-after-kill.txt
  log "processes killed; host: $(cat $E/fail-a-host-after-kill.txt)"
  # The head names the active transaction; reading it is fast, unlike a full status observation.
  TX=$(gcloud storage cat gs://tan-ng-labs-c3-1011-oxwfiry-state/inventory/head.json | jq -r .activeTransaction); echo $TX > $E/fail-a-tx.txt
  [ "$TX" != null ] || die "no active transaction after the kill"
  host 'printf "%s %s\n" "$(readlink -f /run/current-system)" "$(systemctl is-active nagare-switch-rollback.timer)"' | tail -1 > $E/fail-a-host-before-close.txt
  if grep -q ' active$' $E/fail-a-host-before-close.txt; then
    $RUN inventory close $TX --review $(cut -c1-64 $R/fail-a/review.sha256) > $E/fail-a-close-armed.txt 2>&1; rc=$?
    log "close while the timer is armed: exit=$rc: $(q $E/fail-a-close-armed.txt 3)"
    [ $rc != 0 ] || die "close accepted while the rollback timer was armed"
    grep -q -i 'timer' $E/fail-a-close-armed.txt || die "close refused for another reason (read fail-a-close-armed.txt)"
  fi
  log "waiting for the on-host rollback timer"
  for i in $(seq 1 60); do
    st=$(host 'printf "%s %s\n" "$(readlink -f /run/current-system)" "$(systemctl is-active nagare-switch-rollback.timer)"' | tail -1)
    echo "$(date -u +%T) $st" >> $E/fail-a-host-watch.txt
    [ "$st" = "$OLD inactive" ] && break; sleep 10
  done
  [ "$(tail -1 $E/fail-a-host-watch.txt | cut -d' ' -f2-)" = "$OLD inactive" ] || die "host did not revert: $(tail -1 $E/fail-a-host-watch.txt)"
  log "host reverted to the old closure with the timer inactive"
  seq0=$(gcloud storage cat gs://tan-ng-labs-c3-1011-oxwfiry-state/inventory/head.json | jq -r .sequence)
  $RUN inventory resume $TX --yes > $E/fail-a-resume.txt 2>&1; rc=$?
  log "resume exit=$rc: $(q $E/fail-a-resume.txt 3)"
  [ $rc != 0 ] || die "resume did not refuse"
  # F94: the refusal prints only "ambiguous tx at op" without the old-closure reason; the documented
  # property is that resume does not switch again and writes nothing.
  [ "$(host 'readlink -f /run/current-system' | tail -1)" = "$OLD" ] || die "resume switched the host"
  [ "$(gcloud storage cat gs://tan-ng-labs-c3-1011-oxwfiry-state/inventory/head.json | jq -r .sequence)" = "$seq0" ] || die "resume journaled an event"
  ;;
fail-a-close)
  TX=$(cat $E/fail-a-tx.txt); OLD=$(cat $E/fail-a-old-closure.txt)
  [ "$(host 'readlink -f /run/current-system' | tail -1)" = "$OLD" ] || die "host is not on the old closure"
  $RUN inventory close $TX --review $(cut -c1-64 $R/fail-a/review.sha256) > $E/fail-a-close.txt 2>&1; rc=$?
  log "close exit=$rc: $(q $E/fail-a-close.txt 6)"
  [ $rc = 0 ] || die "close refused"
  grep -q 'no effect' $E/fail-a-close.txt || die "close did not settle the activation as no effect"
  [ "$(gcloud storage cat gs://tan-ng-labs-c3-1011-oxwfiry-state/inventory/head.json | jq -r .activeTransaction)" = null ] || die "transaction still active after close"
  # The snapshot follows in fail-a-verify, after the previous lock is restored (status refuses until then, F91).
  ;;
c-failed-exit)
  # Drill C's k3s minor upgrade did not commit: the new system restarted tailscaled and the network,
  # which ended the activation session (F95), and the on-host timer reverted it. Documented exit:
  # resume must not switch again, close settles the activation as no effect, then restore the lock.
  TX=$(gcloud storage cat gs://tan-ng-labs-c3-1011-oxwfiry-state/inventory/head.json | jq -r .activeTransaction); echo $TX > $E/apply-c-tx.txt
  [ "$TX" != null ] || die "no active transaction"
  OLDC=/nix/store/rx0n8pv9qpi14za4vsdk6gipwik9piz2-nixos-system-mp23-c3l-nagare-google-compute-26.11.20260916.b1b8759
  host 'printf "%s %s\n" "$(readlink -f /run/current-system)" "$(systemctl is-active nagare-switch-rollback.timer)"' | tail -1 > $E/apply-c-host-before-exit.txt
  [ "$(cat $E/apply-c-host-before-exit.txt)" = "$OLDC inactive" ] || die "host is not reverted: $(cat $E/apply-c-host-before-exit.txt)"
  seq0=$(gcloud storage cat gs://tan-ng-labs-c3-1011-oxwfiry-state/inventory/head.json | jq -r .sequence)
  $RUN inventory resume $TX --yes > $E/apply-c-resume.txt 2>&1; rc=$?
  log "resume exit=$rc: $(q $E/apply-c-resume.txt 3)"
  [ $rc != 0 ] || die "resume did not refuse"
  [ "$(host 'readlink -f /run/current-system' | tail -1)" = "$OLDC" ] || die "resume switched the host"
  [ "$(gcloud storage cat gs://tan-ng-labs-c3-1011-oxwfiry-state/inventory/head.json | jq -r .sequence)" = "$seq0" ] || die "resume journaled an event"
  $RUN inventory close $TX --review $(cut -c1-64 $R/apply-c/review.sha256) > $E/apply-c-close.txt 2>&1; rc=$?
  log "close exit=$rc: $(q $E/apply-c-close.txt 6)"
  [ $rc = 0 ] || die "close refused"
  grep -q 'no effect' $E/apply-c-close.txt || die "close did not settle the activation as no effect"
  [ "$(gcloud storage cat gs://tan-ng-labs-c3-1011-oxwfiry-state/inventory/head.json | jq -r .activeTransaction)" = null ] || die "transaction still active after close"
  ;;
c-failed-verify)
  OLDC=/nix/store/rx0n8pv9qpi14za4vsdk6gipwik9piz2-nixos-system-mp23-c3l-nagare-google-compute-26.11.20260916.b1b8759
  cp $E/flake.lock.before-c $HF/flake.lock; log "restored the previous flake.lock after the closed failed upgrade"
  idle || die "transaction active"
  snap c-failed; same_data b-rebooted c-failed
  [ "$(grep -o 'current=.*' $E/snap-c-failed/host.txt | cut -d= -f2)" = "$OLDC" ] || die "host not on the old closure"
  grep -q 'timer=inactive' $E/snap-c-failed/host.txt || die "rollback timer still armed"
  ;;
fail-a-verify)
  # Completes fail-a after its close (the timer had already reverted the host when close ran).
  # After a failed upgrade is closed, restore the previous lock (the accepted host inputs); until then
  # status refuses: "reviewed host inputs differ from the selected configuration or lock".
  cp $E/flake.lock.before-a $HF/flake.lock; log "restored the previous flake.lock after the closed failed upgrade"
  idle || die "transaction active"
  OLD=$(cat $E/fail-a-old-closure.txt)
  snap fail-a; same_data 0 fail-a
  [ "$(grep -o 'current=.*' $E/snap-fail-a/host.txt | cut -d= -f2)" = "$OLD" ] || die "host not on the old closure"
  grep -q 'timer=inactive' $E/snap-fail-a/host.txt || die "rollback timer still armed"
  ;;
apply-b)
  idle || die "transaction active"
  repin $REV_A b
  plan apply-b; apply apply-b; snap b; same_data fail-a b
  grep -q "$(echo $REV_A | cut -c1-7)" $E/snap-b/host.txt || die "host is not on the REV_A system"
  reboot b; same_data b b-rebooted
  grep -q 'kernel=6.18.52' $E/snap-b-rebooted/host.txt || die "kernel did not move to 6.18.52 after the reboot"
  ;;
b-observe)
  # F93: apply-b committed the host switch, then stranded on its declared op and was closed (scope
  # kept). Observe the upgraded host as it stands, then the cold start through reviewed power.
  idle || die "transaction active"
  snap b; same_data fail-a b
  grep -q "$(echo $REV_A | cut -c1-7)" $E/snap-b/host.txt || die "host is not on the REV_A system"
  reboot b; same_data b b-rebooted
  grep -q 'kernel=6.18.52' $E/snap-b-rebooted/host.txt || die "kernel did not move to 6.18.52 after the reboot"
  ;;
backup-c) idle || die "transaction active"; backup s3prec ;;
apply-c)
  idle || die "transaction active"
  repin $REV_C c; plan apply-c; apply apply-c; snap c; same_data b c
  grep -q 'v1\.36\.' $E/snap-c/host.txt || die "k3s did not move to 1.36"
  reboot c; same_data c c-rebooted
  grep -q 'v1\.36\.' $E/snap-c-rebooted/host.txt || die "k3s not 1.36 after the reboot"
  grep -q 'kernel=6.18.55' $E/snap-c-rebooted/host.txt || die "kernel did not move to 6.18.55 after the reboot"
  ;;
*) die "unknown phase" ;;
esac
echo "PHASE-OK $PH"
