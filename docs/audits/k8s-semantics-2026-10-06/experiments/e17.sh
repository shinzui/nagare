#!/usr/bin/env bash
# E17 (EP-181): a StatefulSet with the defaults Nagare renders (OrderedReady,
# RollingUpdate, one replica) whose pod-0 crash-loops on the CURRENT template,
# so the pod is at updateRevision and not Ready (unlike E6, where the stuck pod
# was at an old revision). Then:
#   restart: a template-only change, the pod-template annotation
#            `kubectl rollout restart` writes;
#   fix:     a template change that fixes the crash.
# Does the controller replace pod-0 and roll, or stay blocked?
set -uo pipefail
: "${KUBECONFIG:?point at a disposable k3s v1.34.6 cluster}"
NS=e17
log() { echo "{\"t\":$SECONDS,\"case\":\"$1\",\"step\":\"$2\",\"detail\":$3}"; }
state() {
  local sts=$1
  local s; s=$(kubectl get sts "$sts" -n $NS -o json | jq -c '{generation:.metadata.generation, observedGeneration:.status.observedGeneration, currentRevision:.status.currentRevision, updateRevision:.status.updateRevision, readyReplicas:(.status.readyReplicas // 0), updatedReplicas:(.status.updatedReplicas // 0)}')
  local p; p=$(kubectl get pod "$sts-0" -n $NS -o json 2>/dev/null | jq -c '{uid:.metadata.uid[0:8], revision:.metadata.labels["controller-revision-hash"], phase:.status.phase, ready:([.status.conditions[]? | select(.type=="Ready") | .status] | first), restarts:([.status.containerStatuses[]?.restartCount] | first), waiting:([.status.containerStatuses[]?.state.waiting.reason] | first), command:.spec.containers[0].command}' || echo '{"present":false}')
  echo "{\"sts\":$s,\"pod\":$p}"
}
kubectl create namespace $NS >/dev/null
for sts in restart fix; do
kubectl apply -n $NS -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: $sts}
spec:
  replicas: 1
  serviceName: $sts
  selector: {matchLabels: {app: $sts}}
  template:
    metadata: {labels: {app: $sts}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - {name: db, image: "busybox:1.36", command: [sh, -c, "echo crashing; exit 1"]}
YAML
done
# Wait until each pod has crashed at least twice (CrashLoopBackOff).
for i in $(seq 1 30); do
  r1=$(kubectl get pod restart-0 -n $NS -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  r2=$(kubectl get pod fix-0 -n $NS -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  [ "${r1:-0}" -ge 2 ] && [ "${r2:-0}" -ge 2 ] && break; sleep 3
done
log restart "crash-looping at its only revision" "$(state restart)"
log fix "crash-looping at its only revision" "$(state fix)"

# (1) restart: the annotation kubectl rollout restart writes.
kubectl rollout restart sts/restart -n $NS >/dev/null
log restart "rollout restart applied" "{\"template annotations\":$(kubectl get sts restart -n $NS -o json | jq -c .spec.template.metadata.annotations)}"
# (2) fix: the crash fixed in the template.
kubectl patch sts fix -n $NS --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/command","value":["sleep","100000"]}]' >/dev/null
log fix "fixed command applied" "{}"
for i in 1 2 3 4 5 6 7 8 9; do
  sleep 10
  log restart "after ${i}x10s" "$(state restart)"
  log fix "after ${i}x10s" "$(state fix)"
done
log both "controller-manager log lines naming the StatefulSets" "$(docker logs k3d-fp-e17-server-0 2>&1 | grep -i 'statefulset' | grep -E 'e17/(restart|fix)' | tail -8 | jq -Rsc 'split("\n") | map(select(. != ""))')"

# Then: delete pod-0 in each case (EP-181's operation). The replacement is
# created at updateRevision: the restart case still crashes (its template
# still does), the fix case becomes Ready.
for sts in restart fix; do kubectl delete pod "$sts-0" -n $NS --wait=true >/dev/null; done
for i in 1 2 3; do
  sleep 10
  log restart "pod-0 deleted, ${i}x10s later" "$(state restart)"
  log fix "pod-0 deleted, ${i}x10s later" "$(state fix)"
done
