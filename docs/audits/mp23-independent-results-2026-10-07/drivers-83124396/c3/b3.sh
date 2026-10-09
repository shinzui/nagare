#!/usr/bin/env bash
# B3 / google-cdn on mp23-c3m with candidate 83124396: deploy scenario-cdn behind the platform
# Google CDN backend, disable the CDN, retire the site, collect the retained DNS record.
# An exact zone listing is taken after each step.
set -uo pipefail
G=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; RUN=$G/runctl.sh; E=$G/pending-evidence/google-cdn; mkdir -p $E
export CLOUDSDK_ACTIVE_CONFIG_NAME=labs CLOUDSDK_CORE_PROJECT=tan-ng-labs
REPO=/private/tmp/nagare-cand-83124396-src; cd $REPO  # the config loader finds the GHC env from the cwd
FA=$REPO/fixtures/inventory-release/gcp/apps/scenario-cdn; FL=$REPO/fixtures/inventory-release/local/apps/scenario-site
H=scenario-cdn.c3-1012.labs.topagentnetwork.net; RID=standalone:site-scenario-cdn/$H/dns-a
Z=$(gcloud dns managed-zones list --filter="dnsName~c3-1012" --format="value(name)"); echo $Z > $E/zone.txt
die() { echo "B3 FAILED: $*"; exit 1; }
quiet() { grep -v -E '^(  warning|warning: Application|context guard)' "$1" | tail -1 | cut -c1-300; }
dns() { gcloud dns record-sets list --zone $Z --format=json | jq -c '[.[] | select(.type=="A") | {name,ttl,rrdatas}]' > $E/dns-$1.json; }
pa() { local name=$1; shift; "$@" > $E/$name-plan.log 2>&1 || die "$name plan: $(quiet $E/$name-plan.log)"; }
ap() { $RUN inventory apply $G/reviews/$1 --yes > $E/$2-apply.log 2>&1 || die "$2 apply: $(quiet $E/$2-apply.log)"; echo "$2: $(tail -1 $E/$2-apply.log)"; }
dns 0-before
pa deploy $RUN site deploy -f $FA/nagare/Config.hs -C $FL --skip-build --tag c3 --image-resource publication:app-image-scenario-site-c3/scenario-site-c3/oci-image --cdn-backend-resource platform:cloud/nagare-cdn-backend/nagare-cdn-backend --save-plan $G/reviews/cdn-deploy
ap cdn-deploy deploy; dns 1-after-deploy
pa disable $RUN cdn disable $H --save-plan $G/reviews/cdn-disable
ap cdn-disable disable; dns 2-after-disable
pa retire $RUN inventory retire --scope standalone:site-scenario-cdn --out $G/reviews/cdn-retire
ap cdn-retire retire; dns 3-after-retire
pa collect $RUN inventory collect --resource $RID --out $G/reviews/cdn-collect
ap cdn-collect collect; dns 4-after-collect
python3 - $E $H <<'PY' || die "B3 evidence"
import json, sys
E, host = sys.argv[1:]
rec = lambda s: [r for r in json.load(open(f"{E}/dns-{s}.json")) if r["name"] == host + "."]
last = lambda p: [l for l in open(p).read().splitlines() if l.strip()][-1]
steps = ("0-before", "1-after-deploy", "2-after-disable", "3-after-retire", "4-after-collect")
cycle = {s: rec(s) for s in steps}
out = {"site": "scenario-cdn", "host": host, "operator": "candidate 83124396",
       "deploy": last(f"{E}/deploy-apply.log"), "disable": last(f"{E}/disable-apply.log"),
       "retire": last(f"{E}/retire-apply.log"), "collect": last(f"{E}/collect-apply.log"), "records": cycle,
       "cdnTargetAfterDeploy": [r["rrdatas"] for r in cycle["1-after-deploy"]],
       "originAfterDisable": [r["rrdatas"] for r in cycle["2-after-disable"]],
       "retainedAfterRetire": cycle["3-after-retire"] != [], "absentAfterCollect": cycle["4-after-collect"] == []}
json.dump(out, open(f"{E}/result.json", "w"), indent=1, sort_keys=True)
ok = cycle["0-before"] == [] and out["cdnTargetAfterDeploy"] and out["originAfterDisable"] != out["cdnTargetAfterDeploy"] and out["retainedAfterRetire"] and out["absentAfterCollect"]
print(json.dumps({k: out[k] for k in ("cdnTargetAfterDeploy", "originAfterDisable", "retainedAfterRetire", "absentAfterCollect")})); sys.exit(0 if ok else 3)
PY
echo B3-OK
