#!/usr/bin/env bash
# E16 (F77): a database-like StatefulSet mounting a separate claim by name, as
# Nagare's databases do (no volumeClaimTemplates), with the claim deleted out
# of band while the pod runs. Usage: e16.sh delete|retain. The marker is
# written once by exec, so a fresh volume reads "absent", never the marker.
#   delete: the volume keeps the default reclaim policy (local-path: Delete).
#   retain: the operator patches the volume to Retain before the pod goes,
#           then rebinds it to a recreated claim.
set -uo pipefail
: "${KUBECONFIG:?point at a disposable k3s v1.34.6 cluster}"
variant=${1:?delete or retain}
NS=f77-$variant
log() { echo "{\"variant\":\"$variant\",\"t\":$SECONDS,\"step\":\"$1\",\"detail\":$2}"; }
pvc() { kubectl get pvc db-data -n $NS -o json 2>/dev/null | jq -c '{present:true, uid:.metadata.uid[0:8], phase:.status.phase, deleting:(.metadata.deletionTimestamp != null), finalizers:.metadata.finalizers, volume:.spec.volumeName}' || echo '{"present":false}'; }
pod() { kubectl get pod "$1" -n $NS -o json 2>/dev/null | jq -c '{present:true, uid:.metadata.uid[0:8], phase:.status.phase, node:.spec.nodeName, ready:([.status.conditions[]? | select(.type=="Ready") | .status] | first), scheduled:([.status.conditions[]? | select(.type=="PodScheduled") | .message] | first)}' || echo '{"present":false}'; }
pv() { kubectl get pv "$1" -o json 2>/dev/null | jq -c '{present:true, phase:.status.phase, reclaim:.spec.persistentVolumeReclaimPolicy, claim:(.spec.claimRef.uid // "" | .[0:8])}' || echo '{"present":false}'; }
marker() { kubectl exec -n $NS db-0 -- cat /data/marker 2>/dev/null | jq -Rc . || echo '"absent or unreadable"'; }
claim() { kubectl apply -n $NS -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: db-data}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 10Mi}}${1:+, volumeName: $1, storageClassName: local-path}}
YAML
}
kubectl create namespace $NS >/dev/null
claim
kubectl apply -n $NS -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: db}
spec:
  replicas: 1
  serviceName: db
  selector: {matchLabels: {app: db}}
  template:
    metadata: {labels: {app: db}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - {name: db, image: "busybox:1.36", command: [sleep, "100000"], volumeMounts: [{name: data, mountPath: /data}]}
      volumes: [{name: data, persistentVolumeClaim: {claimName: db-data}}]
YAML
kubectl rollout status sts/db -n $NS --timeout=120s >/dev/null
kubectl exec -n $NS db-0 -- sh -c 'echo "written-$(date +%s)" > /data/marker'
volume=$(kubectl get pvc db-data -n $NS -o jsonpath='{.spec.volumeName}')
log "running" "{\"pvc\":$(pvc),\"pv\":$(pv $volume),\"marker\":$(marker)}"

kubectl delete pvc db-data -n $NS --wait=false >/dev/null
sleep 10
log "claim deleted, 10s later" "{\"pvc\":$(pvc),\"pod\":$(pod db-0),\"marker\":$(marker)}"

# Backup while the pod still mounts the claim: a stream out of the running pod.
kubectl exec -n $NS db-0 -- tar -C /data -cf - . > "$TMPDIR/e16-$variant.tar"
log "backup by exec" "{\"bytes\":$(wc -c < "$TMPDIR/e16-$variant.tar"),\"entries\":$(tar -tf "$TMPDIR/e16-$variant.tar" | jq -Rsc 'split("\n") | map(select(. != ""))')}"

# Can a second pod (a backup Job's pod) mount the Terminating claim?
kubectl run reader -n $NS --image=busybox:1.36 --restart=Never --overrides='{"spec":{"terminationGracePeriodSeconds":1,"containers":[{"name":"reader","image":"busybox:1.36","command":["cat","/data/marker"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"db-data"}}]}}' >/dev/null
sleep 10
log "second pod on the terminating claim" "{\"reader\":$(pod reader)}"
kubectl delete pod reader -n $NS --wait=true >/dev/null

if [ "$variant" = retain ]; then
  kubectl patch pv "$volume" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
  log "volume set to Retain" "{\"pv\":$(pv $volume)}"
fi

kubectl delete pod db-0 -n $NS --wait=true >/dev/null
sleep 10
log "pod deleted, 10s later" "{\"pvc\":$(pvc),\"pod\":$(pod db-0),\"pv\":$(pv $volume)}"

if [ "$variant" = retain ]; then
  kubectl patch pv "$volume" --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null
  claim "$volume"
else
  claim
fi
kubectl rollout status sts/db -n $NS --timeout=120s >/dev/null 2>&1
log "claim recreated" "{\"pvc\":$(pvc),\"pod\":$(pod db-0),\"old pv\":$(pv $volume),\"marker\":$(marker)}"
