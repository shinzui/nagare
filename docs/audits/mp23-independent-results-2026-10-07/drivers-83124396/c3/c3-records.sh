#!/usr/bin/env bash
# C3 (mp23-c3m, candidate 83124396) assertions recorded after the runner's apply: copy each check's staged evidence into the
# runner's evidence directory, summarize raw outputs, and record. Usage: c3-records.sh EV
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; REPO=/private/tmp/nagare-cand-83124396-src
EV="$1"; PE=$ROOT/pending-evidence; R=$ROOT/reviews; C=$EV/checks
die() { echo "RECORDS FAILED: $*"; exit 1; }
rec() { (cd $REPO && python3 scripts/scenario-assertions.py record --evidence-dir "$EV" --mode cloud "$@") || die "record $2"; }
[ -f "$EV/cloud-health.json" ] || die "runner plan has not written cloud-health.json"
[ ! -e "$C" ] || die "checks/ already exists"
mkdir -p $C
for d in collision-refusal adoption drift-classification independent-scope-preservation postgresql-backup-restore \
  redis-backup-restore clickhouse-backup-restore volume-backup-restore source-unavailable-recovery backup-freshness \
  retained-data access-grant-revoke shared-history-takeover google-cdn convergence-noop-removal interrupted-recovery f15; do
  cp -R "$PE/$d" "$C/$d" || die "copy $d"
done
rm -f $C/access-grant-revoke/port-forward.log
python3 - "$C" "$R" <<'PY' || exit 1
import json, sys, re
C, R = sys.argv[1:]
last = lambda p: [l for l in open(p).read().splitlines() if l.strip()][-1]
def write(name, value): json.dump(value, open(f"{C}/{name}", "w"), indent=1, sort_keys=True)
pg = open(f"{C}/postgresql-backup-restore/scratch-rows.txt").read().split()
write("postgresql-backup-restore/result.json", {"backup": "nagarectl db backup scenario-pg", "backupResult": last(f"{R}/pg-backup.log"),
  "restore": "nagarectl db restore scenario-pg c3gpg1 --restore-id c3gpgr1 (reviewed, into a scratch database)", "restoreResult": last(f"{R}/pg-restore.log"),
  "scratchRows": pg, "liveRows": open(f"{C}/postgresql-backup-restore/live-rows.txt").read().split(),
  "pointInTime": pg == ["1|scenario-pg-row-1", "2|scenario-pg-row-2"]})
rd = open(f"{C}/redis-backup-restore/scratch-keys.txt").read().split()
write("redis-backup-restore/result.json", {"backup": "nagarectl db backup scenario-redis", "backupResult": last(f"{R}/redis-backup.log"),
  "restore": "nagarectl db restore scenario-redis c3grd1 --restore-id c3grdr1 (reviewed, into a scratch StatefulSet)", "restoreResult": last(f"{R}/redis-restore.log"),
  "scratchValues": rd, "knownKeysRestored": rd == ["scenario-redis-value-1", "scenario-redis-value-2"]})
ch = open(f"{C}/clickhouse-backup-restore/scratch-rows.txt").read().split()
write("clickhouse-backup-restore/result.json", {"backup": "nagarectl db backup scenario-ch", "backupResult": last(f"{R}/ch-backup.log"),
  "restore": "nagarectl db restore scenario-ch c3gch1 --restore-id c3gchr1 (reviewed, into a scratch database)", "restoreResult": last(f"{R}/ch-restore.log"),
  "scratchRows": ch, "knownRowsRestored": "2|scenario-ch-row-2" in ch})
manifest = open(f"{C}/volume-backup-restore/manifest.txt").read()
write("volume-backup-restore/result.json", {"snapshot": "nagarectl storage snapshot scenario-a uploads c3gvol1", "snapshotResult": last(f"{R}/vol-snap.log"),
  "changedAfterSnapshot": "/uploads/scenario-known.txt rewritten after the snapshot",
  "restore": "nagarectl storage restore scenario-a uploads c3gvol1 --restore-id c3gvolr1 (reviewed)", "restoreResult": last(f"{R}/vol-restore.log"),
  "snapshotTimeFileRestored": "be6a2310d65b391f582af08cd1d6eea37c1857fa75bae29ff624f74d1963a927" in manifest})
fresh = [l for l in open(f"{C}/backup-freshness/receipts.txt").read().splitlines() if "freshness" in l]
write("backup-freshness/result.json", {"command": "nagarectl db backup-receipts scenario-pg --check-freshness", "freshness": fresh,
  "healthy": any(l.startswith("Recovery-point freshness: healthy") for l in fresh)})
d = f"{C}/drift-classification"
write("drift-classification/result.json", {"drift": "the scenario-a Knative Service was edited out of band",
  "strictApply": [l for l in open(f"{d}/strict-apply.log").read().splitlines() if "KnownNoEffect" in l][:1],
  "refusalClosedWith": json.load(open(f"{d}/decision.json"))["action"],
  "takeover": "replanned with --take-over-fields and applied", "takeoverResult": last(f"{d}/takeover-apply.log")})
s = f"{C}/shared-history-takeover"
before, after = json.load(open(f"{s}/head-before.json")), json.load(open(f"{s}/head-after.json"))
write("shared-history-takeover/result.json", {"transaction": open(f"{s}/tx.txt").read().strip(),
  "rootA": "application B deploy killed after the Service write; the claim stayed with root A's store client",
  "rootB": "an isolated second operator root on the same GCS history",
  "otherPlanRefused": open(f"{s}/b-other-plan.stderr").read().strip(),
  "plainResumeRefused": open(f"{s}/b-resume-plain.stderr").read().strip(),
  "explicitTakeover": open(f"{s}/b-takeover.stdout").read().strip(),
  "headBefore": {k: before[k] for k in ("generation", "sequence", "activeTransaction")},
  "headAfter": {k: after[k] for k in ("generation", "sequence", "activeTransaction", "executorClaim")}})
# google-cdn/result.json is written by b3.sh with the candidate itself.
p = f"{C}/convergence-noop-removal"
write("convergence-noop-removal/preview-cleanup.json", {"command": "nagarectl preview cleanup (reviewed), repeated until no review remains",
  "applies": [last(f"{p}/apply-{i}.log") for i in (1, 2, 3)], "finalPlan": last(f"{p}/plan-4.log"),
  "before": open(f"{p}/before.txt").read().splitlines(), "after": open(f"{p}/after.txt").read().splitlines()})
PY
check() { jq -e "$2" "$C/$1" >/dev/null || die "evidence check $1: $2"; }
check postgresql-backup-restore/result.json '.pointInTime'
check redis-backup-restore/result.json '.knownKeysRestored'
check clickhouse-backup-restore/result.json '.knownRowsRestored'
check volume-backup-restore/result.json '.snapshotTimeFileRestored'
check backup-freshness/result.json '.healthy'
check google-cdn/result.json '.absentAfterCollect'
check access-grant-revoke/result.json '.subjectListedAfterGrant and .subjectAbsentAfterRevoke'
check retained-data/history-restore.json '.identical | all'
rec --name collision-refusal --summary "A second application claiming scenario-a's hostname was refused at planning with claim-conflict; no review was saved and the history head did not move" --evidence checks/collision-refusal/result.json --evidence checks/collision-refusal/plan.log
rec --name adoption --summary "A restore whose PersistentVolumeClaim already existed without inventory ownership was refused with adoption-required; no review was saved" --evidence checks/adoption/refusal.json
rec --name drift-classification --summary "Out-of-band drift on the scenario-a Service was refused by the strict apply as KnownNoEffect, closed with abandon-refused-operation, and repaired by a reviewed --take-over-fields replan" --evidence checks/drift-classification/result.json --evidence checks/drift-classification/decision.json --evidence checks/drift-classification/ksvc-before.json --evidence checks/drift-classification/ksvc-after.json
rec --name independent-scope-preservation --summary "A reviewed environment change to scenario-a left every other accepted scope, including scenario-b, at its prior revision" --evidence checks/independent-scope-preservation/result.json
rec --name postgresql-backup-restore --summary "A reviewed PostgreSQL backup to GCS restored into a scratch database with exactly the two pre-backup rows, while the live database kept its later row" --evidence checks/postgresql-backup-restore/result.json
rec --name redis-backup-restore --summary "A reviewed Redis backup to GCS restored into a scratch StatefulSet with the known keys" --evidence checks/redis-backup-restore/result.json
rec --name clickhouse-backup-restore --summary "A reviewed ClickHouse backup to GCS restored into a scratch database with the known rows" --evidence checks/clickhouse-backup-restore/result.json
rec --name volume-backup-restore --summary "A reviewed service-volume snapshot restored the snapshot-time file after the live file was changed" --evidence checks/volume-backup-restore/result.json
rec --name source-unavailable-recovery --summary "With the signing key escrowed and the VM stopped through a reviewed host stop, the newest verified scheduled PostgreSQL backup taken after the seed verified from escrow and GCS alone and restored into a disposable PostgreSQL 18 with its known rows" --evidence checks/source-unavailable-recovery/result.json
rec --name backup-freshness --summary "Recovery-point freshness for scenario-pg reports healthy against the hourly objective" --evidence checks/backup-freshness/result.json --evidence checks/backup-freshness/receipts.txt
rec --name retained-data --summary "scenario-retire's stateless companions were collected in dependency order, its PVC collection was refused, and the exported history restored identically into an isolated root" --evidence checks/retained-data/collection.json --evidence checks/retained-data/history-restore.json
rec --name access-grant-revoke --summary "An access grant killed after its transaction began resumed to convergence and listed the subject; the reviewed revoke removed it" --evidence checks/access-grant-revoke/result.json
rec --name shared-history-takeover --summary "An application deploy interrupted in root A could not be planned over or plainly resumed from root B; an explicit takeover from root B converged the same transaction" --evidence checks/shared-history-takeover/result.json
rec --name google-cdn --summary "Candidate 83124396 moved a reviewed site's host record to the Google CDN, back to the VM origin on cdn disable, retained it on retirement and collected it, with exact zone listings after each step" --evidence checks/google-cdn/result.json
echo "RECORDS-DONE $(ls $EV/assertions | wc -l | tr -d ' ')"
