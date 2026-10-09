#!/usr/bin/env bash
# F15 / F31 evidence on mp23-c3m: the net-certmanager controller's image pull through the
# Artifact Registry credential on a fresh VM, and the credential refresher's timeline.
set -uo pipefail
G=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; E=$G/pending-evidence/f15; mkdir -p $E
export KUBECONFIG=$G/config/nagare/kubeconfigs/mp23-c3m.yaml
K() { command kubectl --context mp23-c3m "$@"; }
P=$(K -n knative-serving get pods -l app=net-certmanager-controller -o name | head -1)
K -n knative-serving get $P -o json | jq '{created:.metadata.creationTimestamp, image:.spec.containers[0].image, pullSecrets:.spec.imagePullSecrets, ready:.status.containerStatuses[0].ready}' > $E/controller.json
K -n knative-serving get events --field-selector involvedObject.name=${P#pod/} -o custom-columns=T:.lastTimestamp,R:.reason,M:.message --no-headers | grep -E "Pull" > $E/events.txt
K get secrets -A -o json | jq '[.items[] | select(.type=="kubernetes.io/dockerconfigjson") | {namespace:.metadata.namespace, name:.metadata.name, created:.metadata.creationTimestamp, annotations:(.metadata.annotations // {} | with_entries(select(.key|test("nagare|refresh|expir"))))}]' > $E/pull-secrets.json
K get pods -A --no-headers | awk '{split($3,a,"/"); t++; if (!(a[1]==a[2] && $4=="Running") && $4!="Completed") n++} END {print t" pods, "n+0" not ready"}' | tee $E/pods.txt
jq -c '{ready, image: .image[0:80]}' $E/controller.json; cut -c1-160 $E/events.txt
# Pull-Secret versions right after bootstrap; f15-late compares them after the first token rotation.
K get secrets -A -o json | jq --arg t "$(date -u +%FT%TZ)" '{sampledAt:$t, secrets:[.items[] | select(.type=="kubernetes.io/dockerconfigjson") | {namespace:.metadata.namespace, name:.metadata.name, resourceVersion:.metadata.resourceVersion, created:.metadata.creationTimestamp}]}' > $E/secrets-boot.json
jq -c '[.secrets[] | {namespace, resourceVersion}]' $E/secrets-boot.json
