#!/usr/bin/env bash
# Section 4 drill on mp23-c3l (cloud): PostgreSQL 17 -> 18 side by side; stop at the first failure.
K=/Users/shinzui/.local/state/nagare-verify/mp23-c3l
export KUBECONFIG=$K/config/nagare/kubeconfigs/mp23-c3l.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs
export S4_APP=upg-app S4_OLD=upg-pg S4_NEW=upg-pg18 S4_KCTX=mp23-c3l S4_TAG=s4
export S4_REGISTRY=us-west1-docker.pkg.dev/tan-ng-labs/nagare-c3-1011
export S4_URL=http://upg-app.personal.c3-1011.labs.topagentnetwork.net
# The context's wildcard DNS points at the CDN load balancer; reach Kourier on the VM directly.
IP=$(gcloud compute instances describe nagare-c3-1011 --zone us-west1-a --project tan-ng-labs --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
export S4_RESOLVE=upg-app.personal.c3-1011.labs.topagentnetwork.net:80:$IP
export S4_IMAGE_ARCHIVE=$K/images/scenario-a.tar
for p in ${S4_PHASES:-setup backup add probe-inplace fail1 copy fail2 recopy switch prove retire}; do
  bash $K/s4-drill.sh $K $p > $K/s4/phase-$p.log 2>&1; rc=$?
  echo "$(date -u +%FT%TZ) phase $p rc=$rc $(grep -v -E '^\s*warning' $K/s4/phase-$p.log | tail -1 | cut -c1-300)"
  [ $rc = 0 ] || exit 1
done
echo S4-ALL-OK
