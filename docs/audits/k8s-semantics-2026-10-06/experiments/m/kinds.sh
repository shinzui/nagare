# kind|name|base manifest (yaml, ${V} substituted for spec variant)|spec-change field description
manifest() { # kind variant
case $1 in
configmap) cat <<Y
apiVersion: v1
kind: ConfigMap
metadata: {name: e1, namespace: exp}
data: {k: "v$2"}
Y
;;
secret) cat <<Y
apiVersion: v1
kind: Secret
metadata: {name: e1, namespace: exp}
stringData: {k: "v$2"}
Y
;;
serviceaccount) cat <<Y
apiVersion: v1
kind: ServiceAccount
metadata: {name: e1, namespace: exp}
automountServiceAccountToken: $([ $2 = 1 ] && echo true || echo false)
Y
;;
namespace) cat <<Y
apiVersion: v1
kind: Namespace
metadata: {name: exp-e1, labels: {v: "v$2"}}
Y
;;
resourcequota) cat <<Y
apiVersion: v1
kind: ResourceQuota
metadata: {name: e1, namespace: exp}
spec: {hard: {pods: "1$2"}}
Y
;;
networkpolicy) cat <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: e1, namespace: exp}
spec: {podSelector: {matchLabels: {v: "v$2"}}, policyTypes: [Ingress]}
Y
;;
role) cat <<Y
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: e1, namespace: exp}
rules: [{apiGroups: [""], resources: [configmaps], verbs: [get$([ $2 = 2 ] && echo ', list')]}]
Y
;;
rolebinding) cat <<Y
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: e1, namespace: exp}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: e1}
subjects: [{kind: ServiceAccount, name: e1, namespace: exp}$([ $2 = 2 ] && echo ', {kind: ServiceAccount, name: default, namespace: exp}')]
Y
;;
service) cat <<Y
apiVersion: v1
kind: Service
metadata: {name: e1, namespace: exp}
spec: {selector: {app: e1}, ports: [{port: 8$2, targetPort: 8080}]}
Y
;;
persistentvolumeclaim) cat <<Y
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: e1, namespace: exp}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: "1$2Mi"}}}
Y
;;
deployment) cat <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: e1, namespace: exp}
spec:
  replicas: 1
  selector: {matchLabels: {app: e1d}}
  template:
    metadata: {labels: {app: e1d}, annotations: {v: "v$2"}}
    spec: {containers: [{name: c, image: "registry.k8s.io/pause:3.10"}]}
Y
;;
statefulset) cat <<Y
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: e1, namespace: exp}
spec:
  replicas: 1
  serviceName: e1
  selector: {matchLabels: {app: e1s}}
  template:
    metadata: {labels: {app: e1s}, annotations: {v: "v$2"}}
    spec: {containers: [{name: c, image: "registry.k8s.io/pause:3.10"}]}
Y
;;
cronjob) cat <<Y
apiVersion: batch/v1
kind: CronJob
metadata: {name: e1, namespace: exp}
spec:
  schedule: "0 0 1 1 *"
  suspend: true
  jobTemplate: {spec: {template: {metadata: {annotations: {v: "v$2"}}, spec: {restartPolicy: Never, containers: [{name: c, image: "busybox:1.36", command: ["true"]}]}}}}
Y
;;
job) cat <<Y
apiVersion: batch/v1
kind: Job
metadata: {name: e1, namespace: exp}
spec:
  suspend: $([ $2 = 1 ] && echo true || echo false)
  template: {spec: {restartPolicy: Never, containers: [{name: c, image: "busybox:1.36", command: ["true"]}]}}
Y
;;
ksvc) cat <<Y
apiVersion: serving.knative.dev/v1
kind: Service
metadata: {name: e1, namespace: exp}
spec:
  template:
    metadata: {annotations: {v: "v$2"}}
    spec: {containers: [{image: "ghcr.io/knative/helloworld-go:latest", env: [{name: TARGET, value: "v$2"}]}]}
Y
;;
esac
}
