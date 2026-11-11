. "$(dirname "$0")/lib.sh"
step "P5 EP-248 D3/D8: the builder kubeconfig runs a one-shot Job in the build namespace and nothing else"
MC="$(K -n nagare-system get job nagare-deployer-ci-store-grant -o jsonpath='{.spec.template.spec.containers[0].image}')"
# The three objects a one-shot Job renders (Nagare.Dsl.Job.Render): a tokenless ServiceAccount,
# a default-deny NetworkPolicy, and the Job.
D /bin/bash -c "cat > /work/tmp/build-job.yaml" <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: ep248-build, namespace: team-a-build}
automountServiceAccountToken: false
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ep248-build, namespace: team-a-build}
spec: {podSelector: {matchLabels: {job-name: ep248-build}}, policyTypes: [Ingress, Egress]}
---
apiVersion: batch/v1
kind: Job
metadata: {name: ep248-build, namespace: team-a-build}
spec:
  backoffLimit: 0
  template:
    metadata: {labels: {job-name: ep248-build}}
    spec:
      serviceAccountName: ep248-build
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: build
        image: $MC
        command: ["/bin/sh", "-c", "echo built in a credential-free Job"]
        securityContext: {readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
run BK apply -f /work/tmp/build-job.yaml
run BK -n team-a-build wait job/ep248-build --for=condition=complete --timeout=180s
run BK -n team-a-build logs job/ep248-build
refused BK -n team-a-build create deployment ep248-probe --image="$MC" --dry-run=server
refused BK -n team-a create configmap ep248-probe --from-literal=a=b --dry-run=server
refused BK -n team-a-build get secrets
refused BK -n team-a-build exec job/ep248-build -- true
run BK -n team-a-build delete job ep248-build --wait=true
