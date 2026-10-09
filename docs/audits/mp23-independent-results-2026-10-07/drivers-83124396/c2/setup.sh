#!/usr/bin/env bash
# Step 0 for the 83124396 C2 (runs only after the operator approves the teardown): export, teardown, fresh root, context.
set -euo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad
export DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
OLD=$(cat $S/c2-root); C=/private/tmp/nagare-mp23-cp3.1EQ78L/.cp3-claim
{ mkdir "$C" 2>/dev/null || [ "$(cat $C/owner)" = nagare-verify ]; } && echo nagare-verify > "$C/owner" && date -u +%FT%TZ > "$C/since" && echo "Acceptance C2 for 83124396 (user-approved teardown): export the b74b7e49 C2 store, teardown, fresh bootstrap with the 83124396 payload, C1, full scenario, runner last" > "$C/purpose"
[ "$($OLD/runctl.sh inventory status --json 2>/dev/null | jq -r '.activeTransaction')" = null ] || { echo "SETUP FAILED: old store has an active transaction"; exit 1; }
$OLD/runctl.sh inventory export --out $OLD/evidence-private/pre-teardown-83124396-export >/dev/null 2>&1
echo "exported: $(jq -c '{activeTransaction, n: (.accepted|length)}' $OLD/evidence-private/pre-teardown-83124396-export/head.json)"
k3d cluster delete nagare-local 2>&1 | tail -1
k3d registry delete k3d-registry.localhost >/dev/null 2>&1 || true
echo "containers left: $(docker ps -a --format '{{.Names}}' | tr '\n' ' ')"
ROOT=$(mktemp -d /private/tmp/nagare-mp23-c2-83124396.XXXXXX); chmod 700 $ROOT
mkdir -p $ROOT/config $ROOT/state $ROOT/cache $ROOT/cluster-secrets $ROOT/evidence-private $ROOT/reviews $ROOT/pending-evidence $ROOT/images $ROOT/projection/nagare
(umask 077; cp $OLD/cluster-secrets/sops-config.yaml $OLD/cluster-secrets/grafana-admin.yaml $ROOT/cluster-secrets/)
cp $OLD/images.env $ROOT/; cp -R $OLD/images/. $ROOT/images/; cp $OLD/projection/nagare/Config.hs $ROOT/projection/nagare/
OLDBIN=$(grep -o "/private/tmp/result-[0-9a-f]*-nagare/bin/nagarectl" $OLD/runctl.sh | head -1)
for w in runctl.sh nagarectl-bare.sh runctl-access.sh nagarectl-bare-access.sh; do
  sed "s#$OLD#$ROOT#g; s#$OLDBIN#/private/tmp/result-83124396-nagare/bin/nagarectl#; s#candidate [0-9a-f]\{8\}#candidate 83124396#" $OLD/$w > $ROOT/$w
done
chmod 700 $ROOT/*.sh
grep -l "$OLD\|$OLDBIN" $ROOT/*.sh && { echo "SETUP FAILED: stale wrapper refs"; exit 1; } || true
echo $ROOT > $S/c2-root
cd $ROOT
./runctl.sh version --json
./runctl.sh context create local --mode local --registry-host k3d-registry.localhost:5000 --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups --use 2>&1 | tail -1
./runctl.sh platform root --json | jq -c '{payloadId, revision}'
echo SETUP-OK
