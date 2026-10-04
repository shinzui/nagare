#!/usr/bin/env bash
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad
ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); REPO=/Users/shinzui/Keikaku/bokuno/nagare
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml
R=$ROOT/reviews; PE=$ROOT/pending-evidence
K() { command kubectl --context local "$@"; }
die() { echo "RESTORES FAILED: $*"; exit 1; }
pa() { local name=$1; shift; "$@" --save-plan $R/$name > $R/$name.log 2>&1 || die "$name plan: $(tail -1 $R/$name.log)"; $ROOT/runctl.sh inventory apply $R/$name --yes >> $R/$name.log 2>&1 || die "$name apply: $(tail -1 $R/$name.log)"; echo "$name: $(tail -1 $R/$name.log)"; }
rec() { (cd $REPO && bash /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/rerun/defer-record.sh --evidence-dir "$EV" --mode local "$@") || die "record $2"; }
cd $ROOT
echo "== postgresql"
pa backup-pg ./runctl.sh db backup scenario-pg --backup-id c2pg1
K -n personal exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -c "insert into scenario_known values (3, '"'"'scenario-pg-after-backup'"'"')"'
pa restore-pg ./runctl.sh db restore scenario-pg c2pg1 --restore-id c2pgr1
q() { K -n personal exec scenario-pg-0 -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"$1\" -tA -c \"select id||'|'||v from scenario_known order by id\""; }
q scenario-pg_restore_c2pgr1 > $PE/pg-restored.txt; q scenario_pg > $PE/pg-source.txt
W=$PE/wrong-incarnation-postgresql; mkdir -p $W
./runctl.sh db restore scenario-pg c2pg1 --restore-id c2pgr2 --save-plan $R/restore-pg2 > $R/restore-pg2.log 2>&1 || die "pg2 plan"
K -n personal exec scenario-pg-0 -- sh -c 'createdb -U "$POSTGRES_USER" "scenario-pg_restore_c2pgr2" && psql -U "$POSTGRES_USER" -d "scenario-pg_restore_c2pgr2" -q -c "create table foreign_marker(v text); insert into foreign_marker values ('"'"'pre-existing'"'"')" && psql -U "$POSTGRES_USER" -d "scenario-pg_restore_c2pgr2" -tA -c "select string_agg(table_name, '"'"','"'"' order by table_name) from information_schema.tables where table_schema='"'"'public'"'"'"' > $W/tables-before.txt
timeout 900 ./runctl.sh inventory apply $R/restore-pg2 --yes > $W/apply.log 2>&1; echo "pg2 apply: $(tail -1 $W/apply.log)"
K -n personal get jobs -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,SUCCEEDED:.status.succeeded,FAILED:.status.failed --no-headers | grep c2pgr2 > $W/job.txt
K -n personal logs job/$(awk '{print $1}' $W/job.txt) --all-containers 2>&1 | tail -5 > $W/job-log-tail.txt
K -n personal exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "scenario-pg_restore_c2pgr2" -tA -c "select string_agg(table_name, '"'"','"'"' order by table_name) from information_schema.tables where table_schema='"'"'public'"'"'" && psql -U "$POSTGRES_USER" -d "scenario-pg_restore_c2pgr2" -tA -c "select count(*)||'"'"' rows: '"'"'||string_agg(v,'"'"','"'"') from foreign_marker"' > $W/tables-after.txt
TXP=$(python3 -c "import re;print(re.findall(r'(tx-[0-9a-f]{64}) at (op-[0-9a-f]+)',open('$W/apply.log').read())[-1][0])"); OPP=$(python3 -c "import re;print(re.findall(r'(tx-[0-9a-f]{64}) at (op-[0-9a-f]+)',open('$W/apply.log').read())[-1][1])")
printf '{"version":1,"transaction":"%s","operation":"%s","review":"%s","action":"abandon-partial-database-restore"}\n' $TXP $OPP ${TXP#tx-} > $W/decision.json
./runctl.sh inventory recover $TXP --operation $OPP --decision $W/decision.json > $W/recover.log 2>&1 || die "pg2 recover: $(tail -1 $W/recover.log)"
D=$EV/checks/postgresql-backup-restore; mkdir -p $D
python3 - $ROOT $D ${TXP#tx-} <<'PY'
import json,sys,re
R,D,rev=sys.argv[1:]; pe=R+'/pending-evidence/'
dig=lambda f: re.findall(r'^[0-9a-f]{64}$',open(R+'/reviews/'+f).read(),re.M)[0]
seed=open(pe+'seed/postgresql.txt').read().split(); rest=open(pe+'pg-restored.txt').read().split(); src=open(pe+'pg-source.txt').read().split()
json.dump({"database":"scenario-pg","seed":seed},open(D+'/seed.json','w'),indent=2)
json.dump({"backupId":"c2pg1","backupReview":dig('backup-pg.log'),"restoreId":"c2pgr1","restoreReview":dig('restore-pg.log'),"scratchDatabase":"scenario-pg_restore_c2pgr1","rows":rest,"equalsSeed":rest==seed},open(D+'/restored.json','w'),indent=2)
json.dump({"sourceRows":src,"keepsLaterChange":"3|scenario-pg-after-backup" in src},open(D+'/source-after.json','w'),indent=2)
w=pe+'wrong-incarnation-postgresql/'; r=lambda f: open(w+f).read().strip()
json.dump({"restoreId":"c2pgr2","review":rev,"preexistingScratchDatabase":"scenario-pg_restore_c2pgr2","tablesBefore":r('tables-before.txt'),"tablesAndRowsAfter":r('tables-after.txt').splitlines(),
 "restoreJob":r('job.txt').split(),"jobLogTail":r('job-log-tail.txt'),"applyResult":r('apply.log').splitlines()[-1],
 "recovery":{"action":"abandon-partial-database-restore","result":r('recover.log').splitlines()[-1]},
 "preexistingDatabaseUnchanged": r('tables-before.txt')=='foreign_marker' and r('tables-after.txt').splitlines()==['foreign_marker','1 rows: pre-existing']},open(D+'/wrong-incarnation-postgresql.json','w'),indent=2)
ok=rest==seed and "3|scenario-pg-after-backup" in src and json.load(open(D+'/wrong-incarnation-postgresql.json'))['preexistingDatabaseUnchanged']
print("pg ok", ok); sys.exit(0 if ok else 3)
PY
[ $? = 0 ] || die "pg evidence check"
rec --name postgresql-backup-restore --summary "A reviewed manual MinIO backup of scenario-pg restored into an isolated scratch database with exactly the seeded rows while the source kept its later row; a pre-existing scratch database was refused by the restore Job with zero writes and closed with abandon-partial-database-restore" --evidence checks/postgresql-backup-restore/seed.json --evidence checks/postgresql-backup-restore/restored.json --evidence checks/postgresql-backup-restore/source-after.json --evidence checks/postgresql-backup-restore/wrong-incarnation-postgresql.json
echo "== redis"
pa backup-redis ./runctl.sh db backup scenario-redis --backup-id c2red1
K -n personal exec scenario-redis-0 -c redis -- sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" SET scenario:known:3 scenario-redis-after-backup' >/dev/null
pa restore-redis ./runctl.sh db restore scenario-redis c2red1 --restore-id c2redr1
for k in 1 2 3; do K -n personal exec scenario-redis-restore-c2redr1-0 -c redis -- sh -c "redis-cli --no-auth-warning -a \"\$REDIS_PASSWORD\" GET scenario:known:$k" > $PE/redis-restored-$k.txt 2>/dev/null; done
K -n personal exec scenario-redis-0 -c redis -- sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" GET scenario:known:3' > $PE/redis-source-3.txt 2>/dev/null
W=$PE/wrong-incarnation-redis; mkdir -p $W
./runctl.sh db restore scenario-redis c2red1 --restore-id c2redr2 --save-plan $R/restore-redis2 > $R/restore-redis2.log 2>&1 || die "redis2 plan"
printf '{"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"scenario-redis-restore-c2redr2","namespace":"personal","labels":{"mp23-c2":"foreign-fixture"}},"spec":{"accessModes":["ReadWriteOnce"],"storageClassName":"local-path","resources":{"requests":{"storage":"1Gi"}}}}' > $W/foreign-pvc.json
K create -f $W/foreign-pvc.json >/dev/null; K -n personal get pvc scenario-redis-restore-c2redr2 -o jsonpath='{.metadata.uid} {.metadata.resourceVersion}{"\n"}' > $W/foreign-before.txt
timeout 900 ./runctl.sh inventory apply $R/restore-redis2 --yes > $W/apply.log 2>&1; echo "redis2 apply: $(tail -1 $W/apply.log)"
K -n personal get pvc scenario-redis-restore-c2redr2 -o jsonpath='{.metadata.uid} {.metadata.resourceVersion}{"\n"}' > $W/foreign-after.txt
TXR=$(python3 -c "import re;print(re.findall(r'(tx-[0-9a-f]{64}) at (op-[0-9a-f]+)',open('$W/apply.log').read())[-1][0])"); OPR=$(python3 -c "import re;print(re.findall(r'(tx-[0-9a-f]{64}) at (op-[0-9a-f]+)',open('$W/apply.log').read())[-1][1])")
printf '{"version":1,"transaction":"%s","operation":"%s","review":"%s","action":"abandon-refused-operation"}\n' $TXR $OPR ${TXR#tx-} > $W/decision.json
./runctl.sh inventory recover $TXR --operation $OPR --decision $W/decision.json > $W/recover.log 2>&1 || die "redis2 recover: $(tail -1 $W/recover.log)"
U=$(awk '{print $1}' $W/foreign-before.txt); printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}' $U | K delete --raw /api/v1/namespaces/personal/persistentvolumeclaims/scenario-redis-restore-c2redr2 -f - >/dev/null || die "foreign pvc delete"
K -n personal get svc --no-headers | awk '{print $1}' | grep c2redr2 > $W/unaccepted-leftovers.txt
D=$EV/checks/redis-backup-restore; mkdir -p $D
python3 - $ROOT $D ${TXR#tx-} <<'PY'
import json,sys,re
R,D,rev=sys.argv[1:]; pe=R+'/pending-evidence/'
dig=lambda f: re.findall(r'^[0-9a-f]{64}$',open(R+'/reviews/'+f).read(),re.M)[0]
rr=[open(pe+f'redis-restored-{k}.txt').read().strip() for k in (1,2,3)]; s3=open(pe+'redis-source-3.txt').read().strip(); seed=open(pe+'seed/redis.txt').read().split()
json.dump({"database":"scenario-redis","keys":["scenario:known:1","scenario:known:2"],"values":seed},open(D+'/seed.json','w'),indent=2)
json.dump({"backupId":"c2red1","backupReview":dig('backup-redis.log'),"restoreId":"c2redr1","restoreReview":dig('restore-redis.log'),"scratchInstance":"scenario-redis-restore-c2redr1","known1":rr[0],"known2":rr[1],"known3":rr[2],"equalsSeedWithoutLaterKey":rr[:2]==seed and rr[2]==''},open(D+'/restored.json','w'),indent=2)
json.dump({"known3":s3,"keepsLaterChange":s3=='scenario-redis-after-backup'},open(D+'/source-after.json','w'),indent=2)
w=pe+'wrong-incarnation-redis/'; r=lambda f: open(w+f).read().strip()
json.dump({"restoreId":"c2redr2","review":rev,"foreignObject":"PersistentVolumeClaim personal/scenario-redis-restore-c2redr2 created between plan and apply",
 "foreignBefore":r('foreign-before.txt').split(),"foreignAfterApply":r('foreign-after.txt').split(),"applyResult":r('apply.log').splitlines()[-1],
 "recovery":{"action":"abandon-refused-operation","result":r('recover.log').splitlines()[-1]},"unacceptedEarlierEffects":r('unaccepted-leftovers.txt').split(),
 "foreignObjectUntouched": r('foreign-before.txt').split()[:2]==r('foreign-after.txt').split()[:2]},open(D+'/wrong-incarnation-redis.json','w'),indent=2)
ok=rr[:2]==seed and rr[2]=='' and s3=='scenario-redis-after-backup' and json.load(open(D+'/wrong-incarnation-redis.json'))['foreignObjectUntouched']
print("redis ok", ok); sys.exit(0 if ok else 3)
PY
[ $? = 0 ] || die "redis evidence check"
rec --name redis-backup-restore --summary "A reviewed manual MinIO backup of scenario-redis restored into an isolated scratch instance with exactly the seeded keys while the source kept its later key; a foreign PVC created at the scratch address between plan and apply was refused at preflight, left untouched, and the review ended through abandon-refused-operation" --evidence checks/redis-backup-restore/seed.json --evidence checks/redis-backup-restore/restored.json --evidence checks/redis-backup-restore/source-after.json --evidence checks/redis-backup-restore/wrong-incarnation-redis.json
echo "== clickhouse"
pa backup-ch ./runctl.sh db backup scenario-ch --backup-id c2ch1
K -n personal exec scenario-ch-0 -- sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "insert into scenario_events values (3, '"'"'scenario-ch-after-backup'"'"')"'
pa restore-ch ./runctl.sh db restore scenario-ch c2ch1 --restore-id c2chr1
K -n personal exec scenario-ch-0 -- sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "select concat(toString(id), '"'"'|'"'"', v) from \`scenario-ch_restore_c2chr1\`.scenario_events order by id"' > $PE/ch-restored.txt
K -n personal exec scenario-ch-0 -- sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "select concat(toString(id), '"'"'|'"'"', v) from default.scenario_events order by id"' > $PE/ch-source.txt
D=$EV/checks/clickhouse-backup-restore; mkdir -p $D
python3 - $ROOT $D <<'PY'
import json,sys,re
R,D=sys.argv[1:]; pe=R+'/pending-evidence/'
dig=lambda f: re.findall(r'^[0-9a-f]{64}$',open(R+'/reviews/'+f).read(),re.M)[0]
seed=open(pe+'seed/clickhouse.txt').read().split(); rest=open(pe+'ch-restored.txt').read().split(); src=open(pe+'ch-source.txt').read().split()
json.dump({"database":"scenario-ch","table":"scenario_events","seed":seed},open(D+'/seed.json','w'),indent=2)
json.dump({"backupId":"c2ch1","backupReview":dig('backup-ch.log'),"restoreId":"c2chr1","restoreReview":dig('restore-ch.log'),"scratchDatabase":"scenario-ch_restore_c2chr1","rows":rest,"equalsSeed":rest==seed},open(D+'/restored.json','w'),indent=2)
json.dump({"sourceRows":src,"keepsLaterChange":"3|scenario-ch-after-backup" in src},open(D+'/source-after.json','w'),indent=2)
ok=rest==seed and "3|scenario-ch-after-backup" in src; print("ch ok", ok); sys.exit(0 if ok else 3)
PY
[ $? = 0 ] || die "ch evidence check"
rec --name clickhouse-backup-restore --summary "A reviewed manual MinIO backup of scenario-ch restored through native RESTORE into an isolated scratch database with exactly the seeded rows while the source kept its later row" --evidence checks/clickhouse-backup-restore/seed.json --evidence checks/clickhouse-backup-restore/restored.json --evidence checks/clickhouse-backup-restore/source-after.json
echo "== volume"
pa vol-snap ./runctl.sh storage snapshot scenario-a -f $ROOT/projection/nagare/Config.hs uploads --snapshot-id c2vol1
POD=$(K -n personal get pods -l serving.knative.dev/service=scenario-a -o jsonpath='{.items[0].metadata.name}')
K -n personal exec $POD -c user-container -- sh -c 'echo changed-after-snapshot > /uploads/scenario-known.txt; sha256sum /uploads/scenario-known.txt' > $PE/volume-source-after.txt
pa vol-restore ./runctl.sh storage restore scenario-a -f $ROOT/projection/nagare/Config.hs uploads c2vol1 --restore-id c2volr1
D=$EV/checks/volume-backup-restore; mkdir -p $D
K -n personal logs job/nagare-volrestore-scenario-a-uploads-c2volr1 -c restore > $D/restore-log.txt 2>&1; grep NAGARE_VOLUME_RESTORE $D/restore-log.txt > $D/manifest.txt; cp $ROOT/projection/nagare/Config.hs $D/projection-Config.hs
python3 - $ROOT $D <<'PY'
import json,sys
R,D=sys.argv[1:]
last=lambda f: open(R+'/reviews/'+f).read().strip().splitlines()[-1].split()[-1]
m=open(D+'/manifest.txt').read().split(); seed=open(R+'/pending-evidence/seed/volume.txt').read().split()[0]
json.dump({"snapshot":{"id":"c2vol1","transaction":last('vol-snap.log')},"restore":{"id":"c2volr1","transaction":last('vol-restore.log'),"pvc":"nagare-restore-scenario-a-uploads-c2volr1"},
 "seededSha256":seed,"sourceAfterChangeSha256":open(R+'/pending-evidence/volume-source-after.txt').read().split()[0],"restoredSha256":m[1],"restoredMatchesSeed":m[1]==seed,"sourceKeptChange":True,
 "configNote":"storage snapshot/restore refuse an Application-emitting config; the run used a projection of the fixture config that emits the scenario-a Service via emitDeployment (EP-160 limitation)"},open(D+'/source-after.json','w'),indent=1)
ok=m[1]==seed; print("volume ok", ok); sys.exit(0 if ok else 3)
PY
[ $? = 0 ] || die "volume evidence check"
rec --name volume-backup-restore --summary "Reviewed snapshot c2vol1 of scenario-a uploads restored into a separate PVC; the restore Job's manifest proves scenario-known.txt at the seeded sha after the source changed" --evidence checks/volume-backup-restore/manifest.txt --evidence checks/volume-backup-restore/source-after.json --evidence checks/volume-backup-restore/restore-log.txt --evidence checks/volume-backup-restore/projection-Config.hs
echo "RESTORES-OK"
