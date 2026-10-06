#!/usr/bin/env bash
# E10: status churn at steady state, 4 minutes: ksvc (incl. scale-to-zero), CronJob every minute, Deployment, ResourceQuota, StatefulSet.
. ./lib.sh
jq -n '{apiVersion:"batch/v1",kind:"CronJob",metadata:{name:"e10",namespace:"exp"},spec:{schedule:"* * * * *",successfulJobsHistoryLimit:1,jobTemplate:{spec:{template:{spec:{restartPolicy:"Never",containers:[{name:"c",image:"busybox:1.36",command:["true"]}]}}}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null
rvs() { for r in services.serving.knative.dev/e1 cronjob/e10 deploy/e1 resourcequota/e1 sts/e6a networkpolicy/e1 configmap/e1; do printf '%s=%s ' ${r%%/*} $(kubectl get $r -n exp -o jsonpath='{.metadata.resourceVersion}'); done; echo; }
for i in $(seq 0 8); do echo "t=$((i*30))s $(rvs)"; [ $i -lt 8 ] && sleep 30; done
kubectl get services.serving.knative.dev e1 -n exp -o json | jq -c '{ready:[.status.conditions[]|"\(.type)=\(.status)"]}'
kubectl get pods -n exp -l serving.knative.dev/service=e1 --no-headers | wc -l
