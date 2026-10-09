#!/usr/bin/env bash
# Acceptance C3 runner (candidate 83124396 on mp23-c3m, bootstrapped from its own payload):
# F48 guard (platform root revision), runner plan -> apply back to back, record the staged
# checks, verify interrupted before its marker and re-run, interrupted-recovery, secret scan,
# finalize. Usage: c3-runner.sh
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; REPO=/private/tmp/nagare-cand-83124396-src; REV=83124396
CTX=mp23-c3m; PROJECT=tan-ng-labs; CLUSTER=nagare-c3-1012
FIX=/Users/shinzui/Keikaku/bokuno/nagare/fixtures/inventory-release/gcp/c3-final-target.json; F=$REPO/fixtures/inventory-release/gcp/apps
CLI=$ROOT/runctl-runner.sh; R=$ROOT/reviews; PE=$ROOT/pending-evidence; IP=$PE/interrupted-recovery
EV=$ROOT/evidence/c3-$REV
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/$CTX.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs
export XDG_CONFIG_HOME=$ROOT/config XDG_STATE_HOME=$ROOT/state
export NAGARE_HOST_AGE_KEY_FILE=$ROOT/age-key.txt SSH_KEY=/Users/shinzui/.ssh/google_compute_engine
U=gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory
K() { command kubectl --context $CTX "$@"; }
die() { echo "RUNNER FAILED: $*"; [ -n "${pf:-}" ] && kill $pf 2>/dev/null; rm -f $ROOT/evidence-private/en-runner.env; exit 1; }
rec() { (cd $REPO && python3 scripts/scenario-assertions.py record --evidence-dir "$EV" --mode cloud "$@") || die "record $2"; }
gcp() { (cd $REPO && NAGARECTL_BIN=$CLI bash scripts/rehearse-gcp-inventory-release.sh --context $CTX --expected-project $PROJECT --expected-cluster $CLUSTER --target-fixture $FIX --evidence-dir $EV "$@"); }
head_now() { gcloud storage cat $U/head.json | jq -r '"\(.generation) \(.sequence) \(.activeTransaction)"'; }
en_up() {
  K -n nagare-system port-forward svc/en 28182:80 > /dev/null 2>&1 & pf=$!; sleep 3
  (umask 077; printf 'NAGARE_EN_URL=http://127.0.0.1:28182\nNAGARE_EN_API_KEY=%s\n' \
    "$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)" > $ROOT/evidence-private/en-runner.env)
}
en_down() { kill $pf 2>/dev/null; pf=""; rm -f $ROOT/evidence-private/en-runner.env; }
STAMP=$(date -u +%H%M%S); cd $ROOT
[ ! -e $EV ] || die "evidence dir exists"
WS=$(ls -d $ROOT/state/nagare/$CTX/platform/nagare-0.4.0-831243962c6b-*)
echo "== $(date -u +%T) candidate: unchanged platform scopes plus the runner probe"
$CLI --context $CTX inventory export --out $ROOT/evidence-private/runner-export-$STAMP > /dev/null 2>&1 || die "export"
python3 $REPO/scripts/unchanged-inventory-candidate.py $ROOT/evidence-private/runner-export-$STAMP $R/runner-candidate.json Platform:kourier Platform:cert-manager --add-packaged-scope runner-probe=cluster/examples/hello-knative-service/service.yaml --payload-root $WS || die "candidate"
$CLI --context $CTX inventory compile --input $R/runner-candidate.json --out $R/runner-candidate > $R/runner-compile.log 2>&1 || die "compile: $(tail -1 $R/runner-compile.log)"
en_up
$CLI --context $CTX inventory status --json 2>/dev/null > $PE/status-pre-runner-cand.json
jq -e '.observationComplete == true and .missingProviders == []' $PE/status-pre-runner-cand.json > /dev/null || die "status incomplete: $(jq -c .missingProviders $PE/status-pre-runner-cand.json)"
# F49: a clean context must report zero replaced incarnations before the runner.
jq -e '[.. | strings | select(. == "replaced-incarnation")] | length == 0' $PE/status-pre-runner-cand.json > /dev/null || die "status reports replaced-incarnation findings"
cp $PE/status-pre-runner-cand.json $ROOT/evidence-private/status-pre-runner.json
echo "== $(date -u +%T) F48 guard: the context runs the candidate's payload"
$CLI --context $CTX platform root --json > $ROOT/evidence-private/platform-root.json 2>/dev/null || die "platform root"
jq -e '.revision == "831243962c6b80f91da1028cdab8238ae6acdabd"' $ROOT/evidence-private/platform-root.json > /dev/null || die "context payload is not the candidate: $(jq -c '{payloadId, revision}' $ROOT/evidence-private/platform-root.json)"
echo "== $(date -u +%T) runner plan"
gcp --phase plan --candidate $R/runner-candidate > $R/runner-plan.log 2>&1 || die "runner plan: $(tail -2 $R/runner-plan.log)"
jq -c '[(.operations|length), [.operations[].operation.action.tag]]' $EV/review/review.json
jq '{payloadId, platformVersion, revision, digest}' $ROOT/evidence-private/platform-root.json > $EV/platform-root.json
echo "== $(date -u +%T) runner apply"
gcp --phase apply --yes > $R/runner-apply.log 2>&1 || die "runner apply: $(tail -2 $R/runner-apply.log)"
en_down
jq -c . $EV/run.json
echo "== $(date -u +%T) records"
bash $ROOT/c3-records.sh $EV || die "records"
echo "== $(date -u +%T) verify with final-marker interruption"
$CLI --context $CTX inventory export --out $ROOT/evidence-private/verify-export-$STAMP > /dev/null 2>&1 || die "export"
python3 $REPO/scripts/unchanged-inventory-candidate.py $ROOT/evidence-private/verify-export-$STAMP $R/verify-candidate.json Platform:kourier Platform:cert-manager Platform:runner-probe || die "verify candidate"
$CLI --context $CTX inventory compile --input $R/verify-candidate.json --out $R/verify-candidate > /dev/null 2>&1 || die "verify compile"
head_now > $IP/final-marker-head-before.txt
X1=$ROOT/evidence-private/final-export-1; X=$ROOT/evidence-private/final-export
en_up
gcp --phase verify --candidate $R/verify-candidate > $IP/final-marker-verify-1.log 2>&1 & pid=$!; killed=""
for i in $(seq 1 3000); do
  if [ -f $EV/final-observation.json ] && [ $EV/final-observation.json -nt $R/verify-candidate/candidate.json ]; then
    kill -9 $pid 2>/dev/null; pkill -9 -f "rehearse-managed-resources.sh --phase verify" 2>/dev/null; killed=$(date -u +%T); break
  fi
  kill -0 $pid 2>/dev/null || break; sleep 0.1
done; wait $pid 2>/dev/null
echo "verify killed=${killed:-none} state=$(jq -r .state $EV/run.json)"; [ -n "$killed" ] || die "verify not interrupted"
[ "$(jq -r .state $EV/run.json)" = applied ] || die "marker written before kill"
head_now > $IP/final-marker-head-after-kill.txt
gcp --phase verify --candidate $R/verify-candidate > $IP/final-marker-verify-2.log 2>&1 || die "verify rerun: $(tail -2 $IP/final-marker-verify-2.log)"
head_now > $IP/final-marker-head-after.txt
$CLI --context $CTX inventory export --out $ROOT/evidence-private/final-export > /dev/null 2>&1 || die "final export"
en_down
jq -c . $EV/run.json; echo "noop ops: $(jq '.operations|length' $EV/no-op-review/review.json)"
jq -c '{observationComplete, missingProviders}' $EV/final-observation.json
echo "== $(date -u +%T) interrupted-recovery"
D=$EV/checks/interrupted-recovery
python3 - $ROOT $D $EV <<'PY' || die "interrupted-recovery evidence"
import json, sys
R, D, EV = sys.argv[1:]; P = R + '/pending-evidence/'
I = P + 'interrupted-recovery/'
lines = lambda p: [l for l in open(p).read().splitlines() if l.strip()]
uids = lambda p: [l.split() for l in lines(p)]
def unchanged(before, after):
    a = {tuple(x[:-1]): x[-1] for x in after}
    return all(a.get(tuple(x[:-1])) == x[-1] for x in before)
def stage(name, within, resume):
    status = json.load(open(f'{I}{name}-status.json')); ts = status.get('transactionStatus') or {}
    b, a = uids(f'{I}{name}-uids-before.txt'), uids(f'{I}{name}-uids-after.txt')
    out = {"stage": name, "within": within, "transaction": status['activeTransaction'],
           "killedOperation": [o['operation'] for o in ts.get('operations', []) if o['state'] != 'completed'],
           "uidsBefore": b, "uidsAfter": a, "preInterruptionUidsUnchanged": unchanged(b, a), "resumeResult": resume}
    json.dump(out, open(f'{D}/{name}.json', 'w'), indent=1); return out
db = stage('database-readiness', "application A deploy, before scenario-pg reports ready", lines(f'{I}database-readiness-resume.log')[-1])
cl = stage('cluster-completion', "application B deploy, after the Service write and before readiness; resumed from a second operator root by explicit takeover",
           lines(P + 'shared-history-takeover/b-takeover.stdout')[-1])
acc = json.load(open(P + 'access-grant-revoke/result.json'))
ac = {"stage": "access-grant", "within": "access grant apply, after its transaction began", "transaction": acc['transactionLeftActive'],
      "resumeResult": acc['resume'], "subjectListedAfterResume": acc['subjectListedAfterGrant']}
json.dump(ac, open(f'{D}/access-grant.json', 'w'), indent=1)
h = lambda f: open(I + f).read().split()
fm = {"stage": "final-marker", "within": "runner verify, before the run marker is written", "runStateAfterKill": "applied",
      "rerunLog": lines(I + 'final-marker-verify-2.log')[-1], "runStateAfterRerun": json.load(open(EV + '/run.json'))['state'],
      "storeHead": {"before": h('final-marker-head-before.txt'), "afterKill": h('final-marker-head-after-kill.txt'), "afterRerun": h('final-marker-head-after.txt')},
      "note": "verify has no transaction; the rerun replaced the interrupted no-op review and the store head did not move"}
json.dump(fm, open(f'{D}/final-marker.json', 'w'), indent=1)
ok = all(s['preInterruptionUidsUnchanged'] and s['resumeResult'].startswith('converged') for s in (db, cl)) \
     and ac['resumeResult'].startswith('converged') and fm['runStateAfterRerun'] == 'verified' \
     and fm['storeHead']['before'][:2] == fm['storeHead']['afterRerun'][:2]
print(db['killedOperation'], cl['killedOperation'], fm['storeHead']); sys.exit(0 if ok else 3)
PY
rec --name interrupted-recovery --summary "Killed applies at database readiness, cluster completion (resumed from a second root by explicit takeover) and an access grant each converged through their recorded transaction with pre-interruption UIDs unchanged; verify killed before its marker re-ran to verified with the store head unchanged" --evidence checks/interrupted-recovery/database-readiness.json --evidence checks/interrupted-recovery/cluster-completion.json --evidence checks/interrupted-recovery/access-grant.json --evidence checks/interrupted-recovery/final-marker.json
rec --name convergence-noop-removal --summary "The runner's verify replan of the unchanged platform candidate has zero operations, and reviewed preview cleanup retired pr-scenario and removed its DomainMapping, Service and route while the other routes stayed" --evidence no-op-review/review.json --evidence checks/convergence-noop-removal/preview-cleanup.json
echo "== $(date -u +%T) secret scan"
D=$EV/checks/secret-read-refusal; mkdir -p $D
$CLI --context $CTX secret list scenario-a -f $F/scenario-a/nagare/Config.hs > $D/secret-list.txt 2>&1 || die "secret list"
python3 - $ROOT $EV $D <<'PY' || die "secret scan"
import os, sys, base64, hashlib, json
R, EV, D = sys.argv[1:]
tok = open(R + '/evidence-private/scenario-api-token', 'rb').read(); needles = [tok, base64.b64encode(tok)]
files = 0; matches = []
for root in [EV, R + '/reviews', R + '/pending-evidence']:
    for dp, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(dp, f)
            try: b = open(p, 'rb').read()
            except Exception: continue
            files += 1
            if any(n in b for n in needles): matches.append(os.path.relpath(p, R))
json.dump({"valueSha256": hashlib.sha256(tok).hexdigest(),
           "recordedShaMatches": open(R + '/evidence-private/scenario-api-token.sha256').read().strip() == hashlib.sha256(tok).hexdigest(),
           "forms": ["raw", "base64"], "scannedRoots": ["evidence directory (public)", "saved review directories", "status outputs and pending evidence"],
           "filesScanned": files, "matches": len(matches), "matchedPaths": matches,
           "note": "the value was generated at run time and passed only on stdin to secret set; there is no public secret get"},
          open(D + '/scan.json', 'w'), indent=1)
print("scan", files, len(matches)); sys.exit(0 if not matches else 3)
PY
N=$(jq .filesScanned $D/scan.json)
rec --name secret-read-refusal --summary "The run-time SCENARIO_API_TOKEN was passed only on stdin; secret list prints names only and a scan of $N evidence, review and status files found zero raw or base64 matches (value recorded by SHA-256 only)" --evidence checks/secret-read-refusal/scan.json --evidence checks/secret-read-refusal/secret-list.txt
echo "== $(date -u +%T) finalize"
(cd $REPO && python3 scripts/scenario-assertions.py finalize --evidence-dir "$EV" --mode cloud) 2>&1 | tail -2
echo "RUNNER-DONE"
