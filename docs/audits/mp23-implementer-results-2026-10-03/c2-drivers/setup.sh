#!/usr/bin/env bash
# Step 0 for the 7596632c C2 (runs only after the operator approves the teardown): export, teardown, fresh root, context.
set -euo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad
export DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
OLD=$(cat $S/c2-root); C=/private/tmp/nagare-mp23-cp3.1EQ78L/.cp3-claim
mkdir "$C" && echo nagare-phase-b > "$C/owner" && date -u +%FT%TZ > "$C/since" && echo "Acceptance C2 for 7596632c (user-approved teardown): export the 7d486457 rerun store, teardown, fresh bootstrap with the 7596632c payload, C1, full scenario, runner last" > "$C/purpose"
[ "$($OLD/runctl.sh inventory status --json 2>/dev/null | jq -r '.activeTransaction')" = null ] || { echo "SETUP FAILED: old store has an active transaction"; exit 1; }
$OLD/runctl.sh inventory export --out $OLD/evidence-private/pre-teardown-7596632c-export >/dev/null 2>&1
echo "exported: $(jq -c '{activeTransaction, n: (.accepted|length)}' $OLD/evidence-private/pre-teardown-7596632c-export/head.json)"
k3d cluster delete nagare-local 2>&1 | tail -1
k3d registry delete k3d-registry.localhost >/dev/null 2>&1 || true
echo "containers left: $(docker ps -a --format '{{.Names}}' | tr '\n' ' ')"
ROOT=$(mktemp -d /private/tmp/nagare-mp23-c2-7596632c.XXXXXX); chmod 700 $ROOT
mkdir -p $ROOT/config $ROOT/state $ROOT/cache $ROOT/cluster-secrets $ROOT/evidence-private $ROOT/reviews $ROOT/pending-evidence $ROOT/images $ROOT/projection/nagare
(umask 077; cp $OLD/cluster-secrets/sops-config.yaml $OLD/cluster-secrets/grafana-admin.yaml $ROOT/cluster-secrets/)
cp $OLD/images.env $ROOT/; cp -R $OLD/images/. $ROOT/images/; cp $OLD/projection/nagare/Config.hs $ROOT/projection/nagare/
for w in runctl.sh nagarectl-bare.sh runctl-access.sh nagarectl-bare-access.sh; do
  sed "s#$OLD#$ROOT#g; s#/private/tmp/result-7d486457-nagare/bin/nagarectl#/private/tmp/result-7596632c-nagare/bin/nagarectl#; s#candidate 7d486457#candidate 7596632c#" $OLD/$w > $ROOT/$w
done
chmod 700 $ROOT/*.sh
grep -l "$OLD\|result-7d486457" $ROOT/*.sh && { echo "SETUP FAILED: stale wrapper refs"; exit 1; } || true
echo $ROOT > $S/c2-root
cd $ROOT
./runctl.sh version --json
./runctl.sh context create local --mode local --registry-host k3d-registry.localhost:5000 --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups --use 2>&1 | tail -1
./runctl.sh platform root --json | jq -c '{payloadId, revision}'
echo SETUP-OK
