#!/usr/bin/env bash
# E1: when do resourceVersion and metadata.generation move, per kind.
. ./lib.sh; . m/kinds.sh
status_patch() {
case $1 in
deployment|statefulset) echo '{"status":{"collisionCount":7}}';;
cronjob) echo '{"status":{"lastScheduleTime":"2026-01-01T00:00:00Z"}}';;
resourcequota) echo '{"status":{"used":{"pods":"9"}}}';;
namespace) echo '{"status":{"conditions":[{"type":"ExpProbe","status":"True"}]}}';;
service) echo '{"status":{"conditions":[{"type":"ExpProbe","status":"True","reason":"R","message":"m","lastTransitionTime":"2026-01-01T00:00:00Z"}]}}';;
persistentvolumeclaim) echo '{"status":{"conditions":[{"type":"Resizing","status":"True"}]}}';;
ksvc) echo '{"status":{"annotations":{"exp":"probe"}}}';;
*) echo "";;
esac; }
k=$1; res=$k; [ $k = ksvc ] && res=services.serving.knative.dev
name=e1; [ $k = namespace ] && name=exp-e1
sn() { if [ $k = namespace ]; then kubectl get namespace $name -o json | jq -c --arg l "$1" '{l:$l, uid:.metadata.uid[0:8], rv:.metadata.resourceVersion, gen:.metadata.generation, phase:.status.phase}'; else snap $res $name "$1"; fi; }
manifest $k 1 | kubectl apply --server-side --field-manager=exp -f - >/dev/null; sn create
sleep 8; sn settled-8s
manifest $k 1 | kubectl apply --server-side --field-manager=exp -f - >/dev/null; sn noop-apply
kubectl annotate $res $name -n $NS probe=1 >/dev/null; sn annotate
kubectl label $res $name -n $NS probe=1 >/dev/null; sn label
manifest $k 2 | kubectl apply --server-side --field-manager=exp -f - >/dev/null; sn spec-v2
sp=$(status_patch $k); if [ -n "$sp" ]; then out=$(kubectl patch $res $name -n $NS --subresource=status --type=merge -p "$sp" 2>&1); sn "status-patch:${out:0:60}"; fi
sleep 8; sn settled-8s
