#!/usr/bin/env bash
# E6: StatefulSet (OrderedReady, RollingUpdate defaults, replicas 1): broken update, correction, broken create.
. ./lib.sh
sts() { # name annotation image cmd
  jq -n --arg n "$1" --arg v "$2" --arg img "$3" --argjson cmd "${4:-null}" '{apiVersion:"apps/v1",kind:"StatefulSet",metadata:{name:$n,namespace:"exp"},spec:{replicas:1,serviceName:$n,selector:{matchLabels:{app:$n}},template:{metadata:{labels:{app:$n},annotations:{v:$v}},spec:{terminationGracePeriodSeconds:1,containers:[({name:"c",image:$img} + (if $cmd then {command:$cmd} else {} end))]}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null; }
ssnap() { kubectl get sts $1 -n exp -o json | jq -c '{gen:.metadata.generation,og:.status.observedGeneration,ready:.status.readyReplicas,upd:.status.updatedReplicas,cur:.status.currentReplicas,curRev:.status.currentRevision[-5:],updRev:.status.updateRevision[-5:], nagare_ready: ((.metadata.generation==.status.observedGeneration) and ((.status.readyReplicas//0)>=(.spec.replicas//1)) and ((.status.updatedReplicas//0)>=(.spec.replicas//1)))}' | tr -d '\n'; kubectl get pods -n exp -l app=$1 -o json | jq -c '[.items[]|{rev:.metadata.labels["controller-revision-hash"][-5:],ready:([.status.conditions[]?|select(.type=="Ready")|.status]|first),restarts:(.status.containerStatuses[0].restartCount // 0 | if . > 0 then "r>0" else "r0" end)}]'; }
watchit() { local prev="" s; for i in $(seq 1 $(( $3 * 2 ))); do s=$($1 $2); [ "$s" != "$prev" ] && echo "t=$((i/2))s $s"; prev=$s; sleep 0.5; done; }
kubectl delete sts e1 -n exp --ignore-not-found --wait >/dev/null
CRASH='["sh","-c","exit 1"]'
echo "== E6a good -> crash update -> correcting update"
sts e6a v-good registry.k8s.io/pause:3.10; kubectl rollout status sts/e6a -n exp --timeout=90s >/dev/null; echo "base: $(ssnap e6a)"
sts e6a v-crash busybox:1.36 "$CRASH"; watchit ssnap e6a 30
sts e6a v-fixed registry.k8s.io/pause:3.10; watchit ssnap e6a 60
r=$(kubectl rollout status sts/e6a -n exp --timeout=3s 2>&1); echo "rollout status: rc=$? ${r:0:100}"
echo "-- delete the stuck pod (what an operator must do)"; kubectl delete pod e6a-0 -n exp --wait=false >/dev/null; watchit ssnap e6a 30
echo "== E6c create crashing -> correcting update (F59 shape)"
sts e6c v-crash busybox:1.36 "$CRASH"; watchit ssnap e6c 20
sts e6c v-fixed registry.k8s.io/pause:3.10; watchit ssnap e6c 60
