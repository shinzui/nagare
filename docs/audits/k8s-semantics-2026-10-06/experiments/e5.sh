#!/usr/bin/env bash
# E5: Deployment and E6: StatefulSet mid-rollout, broken update, correction.
. ./lib.sh
dep() { # annotation image cmd
  jq -n --arg v "$1" --arg img "$2" --argjson cmd "${3:-null}" '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:"e1",namespace:"exp"},spec:{replicas:1,progressDeadlineSeconds:40,selector:{matchLabels:{app:"e1d"}},template:{metadata:{labels:{app:"e1d"},annotations:{v:$v}},spec:{containers:[({name:"c",image:$img} + (if $cmd then {command:$cmd} else {} end))]}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null; }
sts() {
  jq -n --arg v "$1" --arg img "$2" --argjson cmd "${3:-null}" '{apiVersion:"apps/v1",kind:"StatefulSet",metadata:{name:"e1",namespace:"exp"},spec:{replicas:1,serviceName:"e1",selector:{matchLabels:{app:"e1s"}},template:{metadata:{labels:{app:"e1s"},annotations:{v:$v}},spec:{containers:[({name:"c",image:$img,readinessProbe:{exec:{command:["true"]},periodSeconds:2}} + (if $cmd then {command:$cmd} else {} end))]}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null; }
dsnap() { kubectl get deploy e1 -n exp -o json | jq -c '{gen:.metadata.generation,og:.status.observedGeneration,avail:([.status.conditions[]|select(.type=="Available")|.status+"/"+.reason]|first),prog:([.status.conditions[]|select(.type=="Progressing")|.status+"/"+.reason]|first),r:.status.replicas,upd:.status.updatedReplicas,ready:.status.readyReplicas,av:.status.availableReplicas,unav:.status.unavailableReplicas, nagare_deploymentAvailable: ((([.status.conditions[]|select(.type=="Available" and .status=="True")]|length)>0) and (.status.observedGeneration==.metadata.generation))}'; }
ssnap() { kubectl get sts e1 -n exp -o json | jq -c '{gen:.metadata.generation,og:.status.observedGeneration,r:.status.replicas,ready:.status.readyReplicas,upd:.status.updatedReplicas,cur:.status.currentReplicas,curRev:.status.currentRevision[-5:],updRev:.status.updateRevision[-5:], nagare_statefulSetReady: ((.metadata.generation==.status.observedGeneration) and ((.status.readyReplicas//0)>=(.spec.replicas//1)) and ((.status.updatedReplicas//0)>=(.spec.replicas//1)))}'; }
watchit() { # fn seconds
  local prev="" s; for i in $(seq 1 $(( $2 * 2 ))); do s=$($1); [ "$s" != "$prev" ] && echo "t=$((i/2))s $s"; prev=$s; sleep 0.5; done; }
echo "== E5 Deployment: bad image update (old pod keeps serving)"
dsnap
dep v-bad registry.invalid/nope:1
watchit dsnap 55
r=$(kubectl rollout status deploy/e1 -n exp --timeout=5s 2>&1); echo "rollout status: rc=$? ${r:0:140}"
echo "== E5b Deployment: crash-looping image update"
dep v-good registry.k8s.io/pause:3.10; kubectl rollout status deploy/e1 -n exp --timeout=60s >/dev/null
dep v-crash busybox:1.36 '["sh","-c","exit 1"]'
watchit dsnap 20
echo "== E6 StatefulSet: crash update"
sts v-good registry.k8s.io/pause:3.10; kubectl rollout status sts/e1 -n exp --timeout=90s >/dev/null; ssnap
sts v-crash busybox:1.36 '["sh","-c","exit 1"]'
watchit ssnap 40
echo "== E6b StatefulSet: correcting update while broken"
sts v-fixed registry.k8s.io/pause:3.10
watchit ssnap 60
kubectl get pods -n exp -l app=e1s -o json | jq -c '.items[]|{n:.metadata.name,rev:.metadata.labels["controller-revision-hash"][-5:],ready:([.status.conditions[]|select(.type=="Ready")|.status]|first),state:(.status.containerStatuses[0].state|keys[0])}'
