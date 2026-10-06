#!/usr/bin/env bash
. ./lib.sh
eval "$(sed -n '/^ssnap()/p;/^watchit()/p' e6.sh)"
sts() { jq -n --arg n "$1" --arg v "$2" --arg img "$3" --argjson cmd "${4:-null}" '{apiVersion:"apps/v1",kind:"StatefulSet",metadata:{name:$n,namespace:"exp"},spec:{replicas:1,podManagementPolicy:"Parallel",serviceName:$n,selector:{matchLabels:{app:$n}},template:{metadata:{labels:{app:$n},annotations:{v:$v}},spec:{terminationGracePeriodSeconds:1,containers:[({name:"c",image:$img} + (if $cmd then {command:$cmd} else {} end))]}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null; }
echo "== E6d Parallel: create crashing -> correcting update"
sts e6d v-crash busybox:1.36 '["sh","-c","exit 1"]'; watchit ssnap e6d 15
sts e6d v-fixed registry.k8s.io/pause:3.10; watchit ssnap e6d 45
