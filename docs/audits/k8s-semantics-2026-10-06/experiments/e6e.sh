#!/usr/bin/env bash
. ./lib.sh
eval "$(sed -n '/^ssnap()/p;/^watchit()/p' e6.sh)"
sts() { jq -n --arg n "$1" --arg c "$2" '{apiVersion:"apps/v1",kind:"StatefulSet",metadata:{name:$n,namespace:"exp"},spec:{replicas:1,serviceName:$n,selector:{matchLabels:{app:$n}},template:{metadata:{labels:{app:$n}},spec:{terminationGracePeriodSeconds:1,containers:[{name:"c",image:"registry.k8s.io/pause:3.10",resources:{requests:{cpu:$c}}}]}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null; }
echo "== E6e OrderedReady: create unschedulable (Pending) -> correcting update"
sts e6e 64; watchit ssnap e6e 10
kubectl get pod e6e-0 -n exp -o jsonpath='{.status.phase}{"\n"}'
sts e6e 10m; watchit ssnap e6e 45
echo "== E6f OrderedReady: good -> unschedulable update -> correcting update"
sts e6f 10m; kubectl rollout status sts/e6f -n exp --timeout=60s >/dev/null; sts e6f 64; watchit ssnap e6f 10; sts e6f 20m; watchit ssnap e6f 45
